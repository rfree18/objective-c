/**
 * @author Serhii Mamontov
 * @copyright © 2010-2019 PubNub, Inc.
 */
#import "PNKeychain+Private.h"
#import <Security/Security.h>
#import "PNHelpers.h"


#pragma mark Static

/**
 * @brief Spin-lock which is used to protect access to shared resources from multiple threads.
 *
 * @since 4.6.2
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpartial-availability"
static os_unfair_lock keychainAccessLock = OS_UNFAIR_LOCK_INIT;
#pragma clang diagnostic pop


NS_ASSUME_NONNULL_BEGIN

#pragma mark - Private interface declaration

@interface PNKeychain ()


#pragma mark - Storage

/**
 * @brief Storage which is used for environment where Keychain access DB not available.
 *
 * @discussion In multi-user systems before user authorize system is unable to provide information
 * about Keychain because it doesn't know for which user. Used only by macOS because iOS is always
 * single user.
 *
 * @return \a NSDictionary which should be used as temporary in-memory Keychain access DB
 * replacement.
 *
 * @since 4.6.2
 */
+ (NSMutableDictionary *)inMemoryStorage;


#pragma mark - Keychain query

/**
 * @brief Help to debug Keychain query error status.
 *
 * @param status One of \c OSStatus types.
 */
+ (void)debugKeychainQueryStatus:(OSStatus)status;

/**
 * @brief Check whether item described with query already exist in Keychain or not.
 *
 * @param query \a NSDictionary which contain base item information which should be checked.
 * @param block GCD block / closure which will be called when check will be completed.
 *     GCD block / closure pass only one argument - whether item exist or not.
 */
+ (void)checkExistingDataWithQuery:(NSMutableDictionary *)query
                   completionBlock:(void(^)(BOOL))block;

/**
 * @brief Allow to search for item in Keychain and if requested will pull out values which it
 * stores.
 *
 * @param query \a NSDictionary which contain base item information which should be found.
 * @param shouldFetchData Flag which specify whether item's data should be returned or not.
 * @param block GCD block / closure which will be called when search will be completed.
 *     GCD block / closure pass two arguments: \c value - searched item stored value if requested;
 *     \c error - whether error occurred or not.
 */
+ (void)searchWithQuery:(NSMutableDictionary *)query
              fetchData:(BOOL)shouldFetchData
        completionBlock:(void(^)(id, BOOL))block;

/**
 * @brief Update item value.
 *
 * @param value Value which should be stored for the item in Keychain.
 * @param query \a NSDictionary which contain base item information which should be updated.
 * @param block GCD block / closure on block which will be called when update will be completed.
 *     GCD block / closure pass only one argument - whether error occurred or not.
 */
+ (void)update:(nullable id)value
         usingQuery:(NSMutableDictionary *)query
    completionBlock:(void(^)(BOOL))block;


#pragma mark - Keychain data archiving

/**
 * @brief Allow to pack passed value to bytes.
 *
 * @discussion This method is used to store values in Keychain which accept only binaries for value.
 *
 * @param data Object which should be packed to binary.
 *
 * @return Packed binary object.
 */
+ (NSData *)packedData:(id)data;

/**
 * @brief Allow to unpack stored value to native objects.
 *
 * @discussion This method is used to extract data stored in Keychain and return native objects.
 *
 * @param data Binary object which should be unpacked.
 *
 * @return Unpacked foundation object.
 */
+ (id)unpackedData:(NSData *)data;


#pragma mark - Misc

/**
 * @brief Location where Keychain replacement for macOS will be stored.
 *
 * @return Full path to the file.
 *
 * @since 4.8.1
 */
+ (NSString *)fileBasedStoragePath;

/**
 * @brief Check whether system is able to provide access to Keychain (even locked) or not.
 *
 * @return \c NO in case if client is used in milti-user macOS environment and user not authorized
 * yet.
 */
+ (BOOL)isKeychainAvailable;

/**
 * @brief Construct dictionary which will describe item storage or access information.
 *
 * @param key Key under which item should be stored or searched.
 *
 * @return Prepared base item description.
 */
+ (NSMutableDictionary *)baseInformationForItemWithKey:(NSString *)key;

#pragma mark -


@end

NS_ASSUME_NONNULL_END


#pragma mark - Interface implementation

@implementation PNKeychain


#pragma mark - Storage

+ (NSMutableDictionary *)inMemoryStorage {
    
    static NSMutableDictionary *_inMemoryStorage;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if TARGET_OS_OSX
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *filePath = [self fileBasedStoragePath];
        NSString *workingDirectory = [filePath stringByDeletingLastPathComponent];
        
        if (![fileManager fileExistsAtPath:workingDirectory isDirectory:NULL]) {
            [fileManager createDirectoryAtPath:workingDirectory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:nil];
        }
        
        NSDictionary *storedData = [NSDictionary dictionaryWithContentsOfFile:filePath];
        _inMemoryStorage = [NSMutableDictionary dictionaryWithDictionary:storedData];
#else
        _inMemoryStorage = [NSMutableDictionary new];
#endif // TARGET_OS_OSX
    });
    
    return _inMemoryStorage;
}


#pragma mark - Storage manipulation

+ (void)storeValue:(id)value
                 forKey:(NSString *)key
    withCompletionBlock:(void(^)(BOOL stored))block {
    
    BOOL keychainAvailable = [self isKeychainAvailable];
    BOOL shouldWriteInMemory = !keychainAvailable;
    
    if (!shouldWriteInMemory) {
        NSMutableDictionary *query = [self baseInformationForItemWithKey:key];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self update:value usingQuery:query completionBlock:block];
        });
    } else {
        pn_trylock(&keychainAccessLock, ^{
            [self inMemoryStorage][key] = value;
            
#if TARGET_OS_OSX
            [[self inMemoryStorage] writeToFile:[self fileBasedStoragePath] atomically:YES];
#endif // TARGET_OS_OSX
            
            if (block) {
                block(YES);
            }
        });
    }
}

+ (void)valueForKey:(NSString *)key withCompletionBlock:(void(^)(id value))block {
    
    BOOL shouldReadFromMemory = ![self isKeychainAvailable];
#if TARGET_OS_OSX
    shouldReadFromMemory = YES;
#endif // TARGET_OS_OSX
    
    if (!shouldReadFromMemory) {
        [self searchWithQuery:[self baseInformationForItemWithKey:key]
                    fetchData:YES
              completionBlock:^(id data, BOOL error) {

            if (block) {
                block(data);
            }
        }];
    } else {
        pn_trylock(&keychainAccessLock, ^{
            block([self inMemoryStorage][key]);
        });
    }
}

+ (void)removeValueForKey:(NSString *)key withCompletionBlock:(void(^)(BOOL))block {
    
    BOOL keychainAvailable = [self isKeychainAvailable];
    BOOL shouldWriteInMemory = !keychainAvailable;
    
    if (!shouldWriteInMemory) {
        __block NSMutableDictionary *query = [self baseInformationForItemWithKey:key];
        
        [self checkExistingDataWithQuery:query completionBlock:^(BOOL exists) {
            if (exists) {
                query = [self baseInformationForItemWithKey:key];
                
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self update:nil usingQuery:query completionBlock:block];
                });
            }
        }];
    } else {
        pn_trylock(&keychainAccessLock, ^{
            [[self inMemoryStorage] removeObjectForKey:key];
            
#if TARGET_OS_OSX
            [[self inMemoryStorage] writeToFile:[self fileBasedStoragePath] atomically:YES];
#endif // TARGET_OS_OSX
            
            if (block) {
                block(YES);
            }
        });
    }
}


#pragma mark - Keychain query

+ (void)debugKeychainQueryStatus:(OSStatus)status {
    
#ifdef DEBUG
    switch (status) {
        case errSecParam:
        case errSecBadReq:
            NSLog(@"Keychain: Wrong set of parameters has been used.");
            break;
        case errSecDuplicateItem:
            NSLog(@"Keychain: Item already exist.");
            break;
        case errSecItemNotFound:
            NSLog(@"Keychain: Item doesn't exist.");
            break;
        default:
            break;
    }
#endif
}

+ (void)checkExistingDataWithQuery:(NSMutableDictionary *)query
                   completionBlock:(void(^)(BOOL))block {
    
    [self searchWithQuery:query fetchData:NO completionBlock:^(id value, BOOL error) {
        if (block) {
            block(value || !error);
        }
    }];
}

+ (void)searchWithQuery:(NSMutableDictionary *)query
              fetchData:(BOOL)shouldFetchData
        completionBlock:(void(^)(id, BOOL))block {
    
    CFDictionaryRef searchedItem = NULL;
    id data = nil;
    
    if (shouldFetchData) {
        query[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
        query[(__bridge id)kSecReturnAttributes] = (__bridge id)kCFBooleanTrue;
    }
    
    OSStatus searchStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query,
                                                (shouldFetchData ? (CFTypeRef *)&searchedItem
                                                                 : NULL));
    [query removeObjectsForKeys:@[(__bridge id)kSecReturnData, (__bridge id)kSecReturnAttributes]];
    
    if (searchStatus != errSecItemNotFound) {
        [self debugKeychainQueryStatus:searchStatus];
    }
    
    if (searchedItem && searchStatus == errSecSuccess &&
        CFDictionaryContainsKey(searchedItem, kSecValueData)) {
        
        NSData *packedData = ((__bridge NSDictionary *)searchedItem)[(__bridge id)kSecValueData];
        data = [self unpackedData:packedData];
    }
    
    if (searchedItem) {
        CFRelease(searchedItem);
    }
    
    if (block) {
        block(data, (searchStatus != errSecSuccess));
    }
}

+ (void)update:(id)value
         usingQuery:(NSMutableDictionary *)query
    completionBlock:(void(^)(BOOL))block {
    
    NSData *packedData = [self packedData:value];
    
    if (packedData) {
        [self checkExistingDataWithQuery:query completionBlock:^(BOOL exist) {
            NSDictionary *data = @{ (__bridge id)(kSecValueData): packedData };
            OSStatus updateStatus = errSecParam;
            
            if (exist) {
                updateStatus = SecItemUpdate((__bridge CFDictionaryRef)query,
                                             (__bridge CFDictionaryRef)data);
            } else {
                [query addEntriesFromDictionary:data];
                
                updateStatus = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
                [query removeObjectsForKeys:data.allKeys];
            }
            
            [self debugKeychainQueryStatus:updateStatus];
            
            if (block) {
                block((updateStatus == errSecSuccess));
            }
        }];
    } else if (value == nil) {
        OSStatus deleteStatus = SecItemDelete((__bridge CFDictionaryRef)query);
        
        [self debugKeychainQueryStatus:deleteStatus];
        
        if (block) {
            block((deleteStatus == errSecSuccess));
        }
    }
}


#pragma mark - Keychain data archiving

+ (NSData *)packedData:(id)data {
    
    NSData *packedData = nil;
    NSError *error = nil;
    
    if (data) {
        if ([data respondsToSelector:@selector(count)]) {
            packedData = [NSJSONSerialization dataWithJSONObject:data
                                                         options:(NSJSONWritingOptions)0
                                                           error:&error];
        } else if ([data isKindOfClass:NSData.class]) {
            packedData = data;
        } else {
            packedData = [(NSString *)data dataUsingEncoding:NSUTF8StringEncoding];
        }
    }
    
    return packedData;
}

+ (id)unpackedData:(NSData *)data {
    
    NSError *error = nil;
    id unpackedData = nil;
    
    if (data) {
        unpackedData = [NSJSONSerialization JSONObjectWithData:data
                                                       options:(NSJSONReadingOptions)0
                                                         error:&error];
        
        if (error != nil) {
            unpackedData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }
    
    return unpackedData ?: data;
}


#pragma mark - Misc

+ (void)updateEntries:(NSArray<NSString *> *)entryNames accessibilityTo:(CFStringRef)accessibility {
    for (NSString *entryKey in entryNames) {
        NSMutableDictionary *query = [self baseInformationForItemWithKey:entryKey];
        query[(__bridge id)kSecReturnAttributes] = (__bridge id)(kCFBooleanTrue);
        query[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
        [query removeObjectForKey:(__bridge id)(kSecAttrAccessible)];
        CFDictionaryRef searchedItem = NULL;
        id data = nil;
        
        OSStatus searchStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query,
                                                    (CFTypeRef *)&searchedItem);
        
        if (searchedItem && searchStatus == errSecSuccess) {
            NSDictionary *entryAttributes = (__bridge NSDictionary *)searchedItem;
            NSString *itemAccessibility = entryAttributes[(__bridge id)(kSecAttrAccessible)];
            
            if (![itemAccessibility isEqualToString:(__bridge id)accessibility]) {
                if (CFDictionaryContainsKey(searchedItem, kSecValueData)) {
                    NSData *packedData = ((__bridge NSDictionary *)searchedItem)[(__bridge id)kSecValueData];
                    data = [self unpackedData:packedData];
                }
                
                SecItemDelete((__bridge CFDictionaryRef)query);
            }
            
            if (data) {
                [self storeValue:data forKey:entryKey withCompletionBlock:nil];
            }
        }
        
        if (searchedItem) {
            CFRelease(searchedItem);
        }
    }
}

+ (NSString *)fileBasedStoragePath {
    
    static NSString *_fileBasedStoragePath;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        NSSearchPathDirectory searchPath = NSApplicationSupportDirectory;
        NSProcessInfo *processInfo = NSProcessInfo.processInfo;
        NSBundle *mainBundle = NSBundle.mainBundle;
        NSArray *paths = NSSearchPathForDirectoriesInDomains(searchPath, NSUserDomainMask, YES);
        
        NSString *baseDirectory = (paths.count > 0 ? paths.firstObject : NSTemporaryDirectory());
        NSString *applicationName = processInfo.processName ?: mainBundle.bundleIdentifier;
        
        NSString *storeDirectory = [baseDirectory stringByAppendingPathComponent:applicationName];
        _fileBasedStoragePath = [storeDirectory stringByAppendingPathComponent:@"pnkc.db"];
    });
    
    return _fileBasedStoragePath;
}

+ (BOOL)isKeychainAvailable {
    
    static BOOL available;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
#if TARGET_OS_OSX
        SecKeychainRef keychain;
        available = SecKeychainCopyDefault(&keychain) == errSecSuccess;
        
        if(available) {
            CFRelease(keychain);
        }
#else
        available = YES;
#endif
    });
    
    return available;
}

+ (NSMutableDictionary *)baseInformationForItemWithKey:(NSString *)key {
    
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    NSMutableDictionary *query = [NSMutableDictionary new];
    
    if (NSClassFromString(@"XCTestExpectation")) {
        bundleIdentifier = @"com.pubnub.objc-tests";
    }
    
    query[(__bridge id)(kSecClass)] = (__bridge id)(kSecClassGenericPassword);
    query[(__bridge id)(kSecAttrSynchronizable)] = (__bridge id)(kCFBooleanFalse);
    query[(__bridge id)(kSecAttrAccessible)] = (__bridge id)(kSecAttrAccessibleAfterFirstUnlock);
    query[(__bridge id)(kSecAttrService)] = bundleIdentifier;
    query[(__bridge id)(kSecAttrAccount)] = key;
    
    return query;
}

#pragma mark - 


@end
