#include "sha.h"
#include "base64.h"
#include <openssl/sha.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#endif

// ESign uses CommonCrypto for resource hashes and CodeDirectory pages. Avoid
// OpenSSL 3's provider lookup for every 4 KiB page on Apple platforms.
void ZSHA::SHA1Digest(const uint8_t* data, size_t size, uint8_t* output)
{
#if defined(__APPLE__)
	if (size <= UINT32_MAX) { CC_SHA1(data, (CC_LONG)size, output); return; }
	CC_SHA1_CTX context;
	CC_SHA1_Init(&context);
	while (size) {
		CC_LONG chunk = (CC_LONG)std::min(size, size_t(1 << 20));
		CC_SHA1_Update(&context, data, chunk);
		data += chunk; size -= chunk;
	}
	CC_SHA1_Final(output, &context);
#else
	::SHA1(data, size, output);
#endif
}

void ZSHA::SHA256Digest(const uint8_t* data, size_t size, uint8_t* output)
{
#if defined(__APPLE__)
	if (size <= UINT32_MAX) { CC_SHA256(data, (CC_LONG)size, output); return; }
	CC_SHA256_CTX context;
	CC_SHA256_Init(&context);
	while (size) {
		CC_LONG chunk = (CC_LONG)std::min(size, size_t(1 << 20));
		CC_SHA256_Update(&context, data, chunk);
		data += chunk; size -= chunk;
	}
	CC_SHA256_Final(output, &context);
#else
	::SHA256(data, size, output);
#endif
}

bool ZSHA::SHA1(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[20];
	SHA1Digest(data, size, hash);
	strOutput.append((const char*)hash, 20);
	return true;
}

bool ZSHA::SHA256(uint8_t* data, size_t size, string& strOutput)
{
	strOutput.clear();
	uint8_t hash[32];
	SHA256Digest(data, size, hash);
	strOutput.append((const char*)hash, 32);
	return true;
}

bool ZSHA::SHA1(const string& strData, string& strOutput)
{
	return ZSHA::SHA1((uint8_t*)strData.data(), strData.size(), strOutput);
}

bool ZSHA::SHA256(const string& strData, string& strOutput)
{
	return ZSHA::SHA256((uint8_t*)strData.data(), strData.size(), strOutput);
}

bool ZSHA::SHA(const string& strData, string& strSHA1, string& strSHA256)
{
	ZSHA::SHA1(strData, strSHA1);
	ZSHA::SHA256(strData, strSHA256);
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHA1Text(const string& strData, string& strOutput)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);

	static const char hex_lower[] = "0123456789abcdef";
	strOutput.clear();
	strOutput.reserve(strSHASum.size() * 2);
	for (size_t i = 0; i < strSHASum.size(); i++) {
		uint8_t c = (uint8_t)strSHASum[i];
		strOutput += hex_lower[c >> 4];
		strOutput += hex_lower[c & 0x0F];
	}
	return (!strOutput.empty());
}

bool ZSHA::SHAFile(const char* szFile, string& strSHA1, string& strSHA256)
{
	strSHA1.clear();
	strSHA256.clear();
#if defined(__APPLE__)
    // Tiny resources dominate Terminal's 62k files. Avoid allocating a VM
    // mapping and tearing it down for each small file.
    int descriptor = open(szFile, O_RDONLY);
    if(descriptor < 0)return false;
    struct stat info;
    if(fstat(descriptor,&info)){close(descriptor);return false;}
    if(info.st_size>=0 && info.st_size<=65536) {
        uint8_t bytes[65536];size_t count=0;
        while(count<(size_t)info.st_size) {
            ssize_t n=read(descriptor,bytes+count,(size_t)info.st_size-count);
            if(n<=0){close(descriptor);return false;}count+=(size_t)n;
        }
        close(descriptor);
        ZSHA::SHA1(bytes,count,strSHA1);ZSHA::SHA256(bytes,count,strSHA256);
        return true;
    }
    close(descriptor);
#endif
	size_t sSize = 0;
	uint8_t* pBase = (uint8_t*)ZFile::MapFile(szFile, 0, 0, &sSize, true);
	// pBase may be NULL, but it's ok, because the file may be empty
	ZSHA::SHA1(pBase, sSize, strSHA1);
	ZSHA::SHA256(pBase, sSize, strSHA256);
	if (NULL != pBase && sSize > 0) {
		ZFile::UnmapFile(pBase, sSize);
	}
	return (!strSHA1.empty() && !strSHA256.empty());
}

bool ZSHA::SHABase64(const string& strData, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHA(strData, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

bool ZSHA::SHABase64File(const char* szFile, string& strSHA1Base64, string& strSHA256Base64)
{
	jbase64 b64;
	string strSHA1;
	string strSHA256;
	SHAFile(szFile, strSHA1, strSHA256);
	strSHA1Base64 = b64.encode(strSHA1);
	strSHA256Base64 = b64.encode(strSHA256);
	return (!strSHA1Base64.empty() && !strSHA256Base64.empty());
}

void ZSHA::Print(const char* prefix, const uint8_t* hash, uint32_t size, const char* suffix)
{
	ZLog::PrintV("%s", prefix);
	for (uint32_t i = 0; i < size; i++) {
		ZLog::PrintV("%02x", hash[i]);
	}
	ZLog::PrintV("%s", suffix);
}

void ZSHA::Print(const char* prefix, const string& strSHASum, const char* suffix)
{
	Print(prefix, (const uint8_t*)strSHASum.data(), (uint32_t)strSHASum.size(), suffix);
}

void ZSHA::PrintData1(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData1(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA1(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, const string& strData, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(strData, strSHASum);
	Print(prefix, strSHASum, suffix);
}

void ZSHA::PrintData256(const char* prefix, uint8_t* data, size_t size, const char* suffix)
{
	string strSHASum;
	ZSHA::SHA256(data, size, strSHASum);
	Print(prefix, strSHASum, suffix);
}
