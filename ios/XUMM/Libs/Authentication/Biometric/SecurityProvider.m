#import "SecurityProvider.h"

// constants
static NSString *const KEY_ALIAS = @"BiometricModuleKey";

// encryption errors
NSString *const ENCRYPTION_ERROR_CANCELLED = @"ENCRYPTION_CANCELLED";
NSString *const ENCRYPTION_ERROR_FAILED = @"ENCRYPTION_FAILED";
NSString *const ENCRYPTION_SUCCESS = @"ENCRYPTION_SUCCESS";

@implementation SecurityProvider

+ (void) generateKey {
  CFErrorRef error = NULL;
  SecAccessControlRef access =
  SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                  kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                  (kSecAccessControlBiometryCurrentSet | kSecAccessControlPrivateKeyUsage),
                                  &error);
  
  if (!access) {
    NSError *err = CFBridgingRelease(error);
    NSLog(@"BiometricModule: Error when setting up SecAccessControlRef: %@", err.localizedDescription);
    return;
  }
  
  NSDictionary *attributes =
  @{
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrTokenID: (id)kSecAttrTokenIDSecureEnclave,
    (id)kSecAttrKeySizeInBits: @(256), // secure enclave *ONLY* support 256 elliptic (secp256r1)
    (id)kSecPrivateKeyAttrs:
      @{ (id)kSecAttrIsPermanent:    @(YES),
         (id)kSecUseAuthenticationUI: (id)kSecUseAuthenticationUIAllow,
         (id)kSecAttrApplicationTag: KEY_ALIAS,
         (id)kSecAttrAccessControl:  (__bridge id)access}
  };
  
  if (access) { CFRelease(access); }
  
  
  SecKeyRef privateKeyRef = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error);
  
  if (!privateKeyRef) {
    NSError *err = CFBridgingRelease(error);
    NSLog(@"BiometricModule: error when generating key OSStatus: %@",  err.localizedDescription);
    return;
  }
  
  // release private key refrence
  CFRelease(privateKeyRef);
}

+ (void) deleteInvalidKey {
  NSDictionary *keyQuery =
  @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrTokenID: (id)kSecAttrTokenIDSecureEnclave,
    (id)kSecAttrApplicationTag: KEY_ALIAS,
  };
  
  OSStatus status = SecItemDelete((__bridge CFDictionaryRef)keyQuery);
  
  if(status != errSecSuccess){
    NSLog(@"BiometricModule: deleteInvalidKey error OSStatus: %d", status);
  }
}

+ (bool) isKeyReady {
  NSDictionary *keyQuery =
  @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrTokenID: (id)kSecAttrTokenIDSecureEnclave,
    (id)kSecAttrApplicationTag: KEY_ALIAS,
  };


  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)keyQuery, nil);
  return status == errSecSuccess;
}

+ (NSString *) signRandomBytes:(LAContext *)authentication_context {
  NSDictionary *keyQuery =
  @{
    (id)kSecClass: (id)kSecClassKey,
    (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrTokenID: (id)kSecAttrTokenIDSecureEnclave,
    (id)kSecAttrApplicationTag: KEY_ALIAS,
    (id)kSecReturnRef: @YES,
    (id)kSecUseAuthenticationContext: authentication_context
  };
  
  // fetch the private key refrence from keychian
  // NOTE: this will not trigger the UI authenctiocation
  SecKeyRef privateKeyRef;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)keyQuery, (CFTypeRef *)&privateKeyRef);
  
  // unable to fetch key refrence from keychain
  if(status != errSecSuccess){
    return ENCRYPTION_ERROR_FAILED;
  }
  
  // generate random bytes to sign
  NSMutableData *randomBytes = [NSMutableData dataWithLength:32];
  int result = SecRandomCopyBytes(kSecRandomDefault, 32, randomBytes.mutableBytes);
  // unable to create random bytes
  if (result != noErr) {
    return ENCRYPTION_ERROR_FAILED;
  }
  
  CFErrorRef error = NULL;
  CFDataRef dataRef = (__bridge CFDataRef)randomBytes;
  
  // Scure Enclave only supports 256
  // NOTE: calling this method with privateKey ref will trigger UI authenctication
  CFDataRef resultRef =
  SecKeyCreateSignature(privateKeyRef,
                        kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                        dataRef,
                        &error);
  
  
  
  // release private key refrence
  CFRelease(privateKeyRef);
  
  // error when creating signature
  if (!resultRef) {
    NSError *err = CFBridgingRelease(error);
    // user cancelled the authentication
    if ([err.domain isEqual:@kLAErrorDomain] &&
        (err.code == kLAErrorUserCancel || err.code == kLAErrorSystemCancel )) {
      return ENCRYPTION_ERROR_CANCELLED;
    }
    // cannot encrypt the data for any reason
    return ENCRYPTION_ERROR_FAILED;
  }
  
  // everything seems fine
  return ENCRYPTION_SUCCESS;
}


@end
