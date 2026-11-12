#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Parses a PKCS#12 and verifies that its private key matches its certificate.
NSDictionary * _Nullable SGReadIdentity(NSData *data, NSString *password, NSError **error);
/// Verifies the CMS content signature. Trust/revocation is a separate check.
NSData * _Nullable SGDecodeProfile(NSData *data, NSError **error);
NS_ASSUME_NONNULL_END
/// Guarded read-only observation of the system installer; nil when unavailable.
FOUNDATION_EXPORT NSDictionary * _Nullable SGSystemInstallationState(NSString * _Nonnull identifier);
NS_ASSUME_NONNULL_BEGIN
/// Verifies a detached code-signing CMS and returns its authenticated cdhash plist.
NSData * _Nullable SGVerifyCodeCMS(NSData *cms, NSData *content, NSData *certificate, NSError **error);
NS_ASSUME_NONNULL_END
