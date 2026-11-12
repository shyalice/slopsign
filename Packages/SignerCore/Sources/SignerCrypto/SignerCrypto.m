#import "SignerCrypto.h"
#include <openssl/pkcs12.h>
#include <openssl/cms.h>
#include <openssl/provider.h>
#include <openssl/x509.h>
static void SGError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Signer.Crypto" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDate *SGDate(const ASN1_TIME *time) {
    struct tm t = {0};
    if (!time || ASN1_TIME_to_tm(time, &t) != 1) return nil;
    NSDateComponents *c = [NSDateComponents new];
    c.year=t.tm_year+1900; c.month=t.tm_mon+1; c.day=t.tm_mday;
    c.hour=t.tm_hour; c.minute=t.tm_min; c.second=t.tm_sec;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return [cal dateFromComponents:c];
}
NSDictionary *SGReadIdentity(NSData *data, NSString *password, NSError **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ OSSL_PROVIDER_load(NULL,"default"); OSSL_PROVIDER_load(NULL,"legacy"); });
    const unsigned char *ptr=data.bytes;
    PKCS12 *p12=d2i_PKCS12(NULL,&ptr,(long)data.length);
    EVP_PKEY *key=NULL; X509 *cert=NULL; STACK_OF(X509) *ca=NULL;
    if (!p12 || PKCS12_parse(p12,password.UTF8String,&key,&cert,&ca)!=1 || !key || !cert || X509_check_private_key(cert,key)!=1) {
        SGError(error,@"Unable to open P12. Check the password and private key.");
        PKCS12_free(p12); EVP_PKEY_free(key); X509_free(cert); sk_X509_pop_free(ca,X509_free); return nil;
    }
    char name[1024]={0}; X509_NAME_get_text_by_NID(X509_get_subject_name(cert),NID_commonName,name,sizeof(name));
    unsigned char *der=NULL; int length=i2d_X509(cert,&der);
    NSDictionary *result=@{@"name": [NSString stringWithUTF8String:name] ?: @"Cert",
        @"certificate": [NSData dataWithBytes:der length:MAX(length,0)],
        @"expires": SGDate(X509_get0_notAfter(cert)) ?: [NSDate distantPast],
        @"created": SGDate(X509_get0_notBefore(cert)) ?: [NSDate distantPast]};
    OPENSSL_free(der); PKCS12_free(p12); EVP_PKEY_free(key); X509_free(cert); sk_X509_pop_free(ca,X509_free);
    return result;
}
NSData *SGDecodeProfile(NSData *data, NSError **error) {
    const unsigned char *ptr=data.bytes;
    CMS_ContentInfo *cms=d2i_CMS_ContentInfo(NULL,&ptr,(long)data.length);
    BIO *out=BIO_new(BIO_s_mem()); NSData *result=nil;
    if (cms && out && CMS_verify(cms,NULL,NULL,NULL,out,CMS_NO_SIGNER_CERT_VERIFY|CMS_BINARY)==1) {
        char *bytes=NULL; long len=BIO_get_mem_data(out,&bytes);
        if (len>0) result=[NSData dataWithBytes:bytes length:len];
    }
    if (!result) SGError(error,@"Invalid mobileprovision CMS signature.");
    BIO_free(out); CMS_ContentInfo_free(cms); return result;
}
static BOOL SGVerifyCodeDirectoryHashV2(CMS_SignerInfo *info, NSData *content) {
    ASN1_OBJECT *oid=OBJ_txt2obj("1.2.840.113635.100.9.2",1);
    int index=CMS_signed_get_attr_by_OBJ(info,oid,-1); ASN1_OBJECT_free(oid);
    if (index<0) return NO;
    X509_ATTRIBUTE *attribute=CMS_signed_get_attr(info,index);
    if (X509_ATTRIBUTE_count(attribute)!=1) return NO;
    ASN1_TYPE *value=X509_ATTRIBUTE_get0_type(attribute,0);
    if (!value || value->type!=V_ASN1_SEQUENCE) return NO;
    const unsigned char *begin=ASN1_STRING_get0_data(value->value.sequence), *cursor=begin;
    long length=ASN1_STRING_length(value->value.sequence);
    STACK_OF(ASN1_TYPE) *sequence=d2i_ASN1_SEQUENCE_ANY(NULL,&cursor,length);
    BOOL matches=NO;
    if (sequence && sk_ASN1_TYPE_num(sequence)==2 && cursor==begin+length) {
        ASN1_TYPE *algorithm=sk_ASN1_TYPE_value(sequence,0), *digest=sk_ASN1_TYPE_value(sequence,1);
        unsigned char expected[EVP_MAX_MD_SIZE]; unsigned int expectedLength=0;
        if (algorithm->type==V_ASN1_OBJECT && OBJ_obj2nid(algorithm->value.object)==NID_sha256 &&
            digest->type==V_ASN1_OCTET_STRING &&
            EVP_Digest(content.bytes,content.length,expected,&expectedLength,EVP_sha256(),NULL)==1 &&
            ASN1_STRING_length(digest->value.octet_string)==expectedLength) {
            matches=CRYPTO_memcmp(expected,ASN1_STRING_get0_data(digest->value.octet_string),expectedLength)==0;
        }
    }
    sk_ASN1_TYPE_pop_free(sequence,ASN1_TYPE_free);
    return matches;
}
NSData *SGVerifyCodeCMS(NSData *data, NSData *content, NSData *certificate, NSError **error) {
    const unsigned char *ptr=data.bytes;
    CMS_ContentInfo *cms=d2i_CMS_ContentInfo(NULL,&ptr,(long)data.length);
    BIO *input=BIO_new_mem_buf(content.bytes,(int)content.length);
    BIO *output=BIO_new(BIO_s_mem()); NSData *result=nil;
    if (cms && input && output && CMS_verify(cms,NULL,NULL,input,output,CMS_NO_SIGNER_CERT_VERIFY|CMS_BINARY)==1) {
        STACK_OF(X509) *signers=CMS_get0_signers(cms);
        if (signers && sk_X509_num(signers)==1) {
            unsigned char *der=NULL;int len=i2d_X509(sk_X509_value(signers,0),&der);
            BOOL matches=len>0 && [[NSData dataWithBytes:der length:len] isEqual:certificate];OPENSSL_free(der);
            if (matches) {
                STACK_OF(CMS_SignerInfo) *infos=CMS_get0_SignerInfos(cms);
                CMS_SignerInfo *info=sk_CMS_SignerInfo_value(infos,0);
                ASN1_OBJECT *oid=OBJ_txt2obj("1.2.840.113635.100.9.1",1);
                int idx=CMS_signed_get_attr_by_OBJ(info,oid,-1);ASN1_OBJECT_free(oid);
                if (idx>=0 && SGVerifyCodeDirectoryHashV2(info,content)) {
                    X509_ATTRIBUTE *attr=CMS_signed_get_attr(info,idx);
                    ASN1_TYPE *value=X509_ATTRIBUTE_get0_type(attr,0);
                    if (value && value->type==V_ASN1_OCTET_STRING) result=[NSData dataWithBytes:value->value.octet_string->data length:value->value.octet_string->length];
                }
            }
        }
        sk_X509_free(signers);
    }
    if (!result) SGError(error,@"Mach-O CMS signature verification failed.");
    BIO_free(input);BIO_free(output);CMS_ContentInfo_free(cms);return result;
}
