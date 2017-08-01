//
//  WMSession.m
//  Webim-Client
//
//  Created by Oleg Bogumirsky on 9/5/13.
//  Copyright (c) 2013 WEBIM.RU Ltd. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "WMSession.h"

#import "AFNetworking.h"

#import "WMChat.h"
#import "WMMessage.h"
#import "WMOperator.h"
#import "WMVisitor.h"
#import "WMUIDGenerator.h"
#import "WMChat+Private.h"
#import "WMMessage+Private.h"
#import "WMOperator+Private.h"

#import "NSUserDefaults+ClientData.h"
#import "NSNull+Checks.h"


#ifdef DEBUG
#define WMDebugLog(format, ...) NSLog(format, ## __VA_ARGS__)
#else
#define WMDebugLog(format, ...)
#endif

static NSString *const APIDeltaPath = @"/l/v/delta";
static NSString *const APIActionPath = @"/l/v/action";
static NSString *const APIHistoryPath = @"/l/v/history";
static NSString *const APIUploadPath = @"/l/v/upload";

static NSString *DefaultClientTitle = @"iOS Client";

static const NSTimeInterval ReconnectTimeInterval = 30; // < seconds
static const NSTimeInterval OnlineDeltaPatchTimeInterval = 30;
static const NSTimeInterval PatchTimerCheckTimeInterval = 4;

NSString *const WMVisitorParameterDisplayName = @"display_name";
NSString *const WMVisitorParameterPhone = @"phone";
NSString *const WMVisitorParameterEmail = @"email";
NSString *const WMVisitorParameterICQ = @"icq";
NSString *const WMVisitorParameterProfileURL = @"profile_url";
NSString *const WMVisitorParameterAvatarURL = @"avatar_url";
NSString *const WMVisitorParameterID = @"id";
NSString *const WMVisitorParameterLogin = @"login";
NSString *const WMVisitorParameterCRC = @"crc";


@interface WMSession ()

@property (nonatomic, strong) NSNumber *revision;
@property (nonatomic, assign) BOOL isStopped;

@end


@implementation WMSession {
    AFHTTPClient *client_;
    NSNumber *activeDeltaRevisionNumber_;
    BOOL sessionEstablished_; // YES after successful response of initial delta.
    BOOL sessionStarted_; // YES after first call to startSession method.
    BOOL gettingInitialDelta_;
    NSDate *lastFullUpdateDate_;
    NSTimer *patchDeltaTimer_;
    NSDictionary *userDefinedVisitorFields_;
    
    BOOL lastComposedSentIsTyping_;
    BOOL lastComposedCachedIsTyping_;
    NSString *lastComposedSentDraft_;
    NSString *lastComposedCachedDraft_;
    NSDate *lastComposedSentDate_;
    NSTimer *composingTimer_;
    BOOL isMultiUser_;
    NSString *userId_; // Only for multi-user session.
}


// MARK: - Initializers / Deinitializers

- (id)initWithAccountName:(NSString *)accountName
                 location:(NSString *)location
                 delegate:(id<WMSessionDelegate>)delegate
            visitorFields:(NSDictionary *)visitorFields
              isMultiUser:(BOOL)isMultiUser {
    if ((self = [super initWithAccountName:accountName
                                  location:location])) {
        _delegate = delegate;
        userDefinedVisitorFields_ = visitorFields;
        
        NSURL *baseURL = [NSURL URLWithString:self.host];
        client_ = [AFHTTPClient clientWithBaseURL:baseURL];
        [client_ setParameterEncoding:AFFormURLParameterEncoding];
        [client_ setDefaultHeader:@"Accept"
                            value:@"text/json, application/json"];
        [client_ registerHTTPOperationClass:[AFJSONRequestOperation class]];
        
        [self enableObservingForNotifications:YES];
        
        isMultiUser_ = isMultiUser;
        if (isMultiUser) {
            NSAssert([NSNull valueOf:visitorFields] != nil, @"'visitorFields' must be defined for multi-user session.");
            
            id uid = visitorFields[@"id"];
            NSAssert([NSNull valueOf:uid] != nil, @"Field 'id' must be defined in 'visitorFields'.");
            if ([uid isKindOfClass:[NSNumber class]]) {
                userId_ = [(NSNumber *)uid stringValue];
            } else {
                userId_ = (NSString *)uid;
            }
        }
    }
    
    return self;
}

- (id)initWithAccountName:(NSString *)accountName
                 location:(NSString *)location
                 delegate:(id<WMSessionDelegate>)delegate
            visitorFields:(NSDictionary *)visitorFields {
    return [self initWithAccountName:accountName
                            location:location
                            delegate:delegate
                       visitorFields:visitorFields
                         isMultiUser:NO];
}

- (id)initWithAccountName:(NSString *)accountName
                 location:(NSString *)location
                 delegate:(id<WMSessionDelegate>)delegate {
    return [self initWithAccountName:accountName
                            location:location
                            delegate:delegate
                       visitorFields:nil];
}

- (void)dealloc {
    [self enableObservingForNotifications:NO];
}


// MARK: - APIs

// MARK: - Session methods

- (void)startSession:(WMResponseCompletionBlock)block {
    gettingInitialDelta_ = YES;
    sessionStarted_ = YES;
    self.isStopped = NO;
    
    NSDictionary *storedValues = [self unarchiveClientData];
    id visitor = storedValues[WMStoreVisitorKey];
    id visitSessionId = storedValues[WMStoreVisitSessionIDKey];
    id pageID = storedValues[WMStorePageIDKey];
    id ext = storedValues[WMStoreVisitorExtKey];
    
    BOOL extFieldsTheSame = [self dictionary:ext
                         isEqualToDictionary:userDefinedVisitorFields_];
    
    if ((pageID != nil) &&
        extFieldsTheSame) {
        gettingInitialDelta_ = NO;
        [self getDeltaWithComet:NO
                completionBlock:^(NSDictionary *result) {
                    if (result == nil) {
                        sessionEstablished_ = YES;
                    }
                    CALL_BLOCK(block, result == nil);
                }];
        
        return;
    }
    
    id extVisitorObject = nil;
    if (userDefinedVisitorFields_ != nil) {
        extVisitorObject = [self jsonizedStringFromObject:userDefinedVisitorFields_];
    } else {
        extVisitorObject = [NSNull null];
    }
    
    NSDictionary *parameters = @{
                                 @"event": @"init",
                                 @"location": self.location,
                                 @"visit-session-id": (visitSessionId == nil) ? [NSNull null] : visitSessionId,
                                 @"title": DefaultClientTitle,
                                 @"since": @0,
                                 @"visitor": (visitor == nil) ? [NSNull null] : [self jsonizedStringFromObject:visitor],
                                 @"visitor-ext": extVisitorObject,
                                 @"ts": @([[NSDate date] timeIntervalSince1970]),
                                 @"platform": @"ios",
                                 };
    
    NSString *pushToken = [[NSUserDefaults standardUserDefaults] valueForKey:@"WMDeviceTokenKey"];
    if ([pushToken isKindOfClass:[NSString class]] &&
        (pushToken.length > 0)) {
        NSMutableDictionary *extParams = [parameters mutableCopy];
        [extParams setValue:pushToken forKey:@"push-token"];
        parameters = extParams;
    }
    
    if (activeDeltaRevisionNumber_ != nil) {
        CALL_BLOCK(block, NO);
        
        return;
    }
    
    activeDeltaRevisionNumber_ = @0;
    [client_ getPath:APIDeltaPath
          parameters:parameters
             success:^(AFHTTPRequestOperation *operation, id responseObject) {
                 activeDeltaRevisionNumber_ = nil;
                 gettingInitialDelta_ = NO;
                 
                 WMDebugLog(@"Init Delta Response:\n%@", responseObject);
                 
                 BOOL hasError = [self handleErrorInResponse:responseObject];
                 if (!hasError) {
                     sessionEstablished_ = YES;
                     [self processGetInitialDelta:responseObject];
                     [self startGettingDeltaWithComet];
                 }
                 
                 CALL_BLOCK(block, !hasError);
             } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                 activeDeltaRevisionNumber_ = nil;
                 gettingInitialDelta_ = NO;
                 
                 if (operation.isCancelled) {
                     CALL_BLOCK(block, NO);
                     
                     return;
                 }
                 
                 WMDebugLog(@"Error: unable to start with location.\n%@", error);
                 
                 [self processErrorAPIResponse:operation
                                         error:error];
                 
                 CALL_BLOCK(block, NO);
             }];
}

- (NSDictionary *)unarchiveClientData {
    if(isMultiUser_) {
        return [NSUserDefaults unarchiveClientDataMU:userId_];
    } else {
        return [NSUserDefaults unarchiveClientData];
    }
}

- (BOOL)dictionary:(NSDictionary *)left
isEqualToDictionary:(NSDictionary *)right {
    if ((left == nil) ||
        (right == nil)) {
        return NO;
    }
    
    if (((left != nil) && (right == nil)) ||
        ((left == nil) && right != nil)) {
        return YES;
    }
    
    return [left isEqualToDictionary:right];
}

- (NSString *)jsonizedStringFromObject:(id)inputObject {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:inputObject
                                                   options:0
                                                     error:&error];
    
    if (error != nil) {
        NSLog(@"Unable to serialize jsonObject: %@", error.localizedDescription);
        
        return nil;
    }
    
    NSString *output = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
    
    return output;
}

- (void)stopSession {
    [patchDeltaTimer_ invalidate];
    patchDeltaTimer_ = nil;
    [composingTimer_ invalidate];
    composingTimer_ = nil;
    [self cancelGettingDeltaWithComet];
    self.isStopped = YES;
}

- (void)refreshSessionWithCompletionBlock:(WMResponseCompletionBlock)block {
    [self cancelGettingDeltaWithComet];
    [self getDeltaWithComet:NO
            completionBlock:^(NSDictionary *statusData) {
                CALL_BLOCK(block, statusData == nil);
            }];
}

- (BOOL)areHintsEnabled {
    id hintsEnabled = [self unarchiveClientData][WMStoreAreHintsEnabled];
    
    if ([hintsEnabled  isEqual: @1]) {
        return true;
    }
    
    return false;
}


// MARK: - Delta methods

- (void)getDeltaWithComet:(BOOL)useComet
          completionBlock:(void (^)(NSDictionary *))block {
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    
    if ((client_ == nil) &&
        (pageID.length == 0)) {
        CALL_BLOCK(block, @{@"error": @"Uninitialized"});
        
        return;
    }
    
    if (pageID.length == 0) {
        // Lost archieved data. Session should be re-initialized
        [self stopSession];
        
        if ([self.delegate respondsToSelector:@selector(sessionRestartRequired:)]) {
            [self.delegate sessionRestartRequired:self];
        }
        
        return;
    }
    
    if (self.revision == nil) {
        self.revision = @0;
    }
    
    if (activeDeltaRevisionNumber_ != nil) {
        [self cancelGettingDeltaWithComet];
    }
    
    NSDictionary *params = @{
                             @"page-id": pageID,
                             @"since": self.revision,
                             @"ts": @([[NSDate date] timeIntervalSince1970]),
                             @"respond-immediately" : useComet ? @"false" : @"true",
                             };
    
    activeDeltaRevisionNumber_ = self.revision;
    [client_ getPath:APIDeltaPath
          parameters:params
             success:^(AFHTTPRequestOperation *operation, id responseObject) {
                 activeDeltaRevisionNumber_ = nil;
                 
                 WMDebugLog(@"Get Delta response:\n%@", responseObject);
                 
                 [self handleErrorInResponse:responseObject];
                 [self processGetDelta:responseObject];
                 
                 if (!useComet) {
                     [self startGettingDeltaWithComet];
                 }
                 
                 if (block != nil) {
                     block(nil);
                 }
             } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                 activeDeltaRevisionNumber_ = nil;
                 if (operation.isCancelled) {
                     if (block != nil) {
                         block (nil);
                     }
                     
                     return;
                 }
                 
                 WMDebugLog(@"Error: %@", error);
                 
                 if (operation.response == nil) {
                     [self processErrorAPIResponse:operation
                                             error:error];
                 }
                 if (block != nil) {
                     block( @{@"error": error});
                 }
             }];
}

- (void)startGettingDeltaWithComet {
    if (self.isStopped) {
        return;
    }
    
    [NSObject dispatchSyncOnMainThreadBlock:^{
        if (activeDeltaRevisionNumber_ != nil) {
            return;
        }
        
        if (!sessionEstablished_) {
            [self startSession:nil];
            
            return;
        }
        
        [self getDeltaWithComet:YES
                completionBlock:^(NSDictionary *errorData) {
                    if (errorData == nil) {
                        [self performSelector:@selector(startGettingDeltaWithComet)
                                   withObject:nil
                                   afterDelay:0.3];
                    }
                }];
    }];
}

- (void)cancelGettingDeltaWithComet {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(startGettingDeltaWithComet)
                                               object:nil];
    [client_ cancelAllHTTPOperationsWithMethod:@"GET"
                                          path:APIDeltaPath];
}

- (void)getDeltaWithCompletionBlock:(void (^)(NSDictionary *statusData))block {
    [self getDeltaWithComet:NO
            completionBlock:block];
}


// MARK: - Chat methods

- (NSString *)startChatWithClientSideId:(NSString *)clientSideId
                        completionBlock:(WMResponseCompletionBlock)block {
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(block, NO);
        
        return nil;
    }
    
    if (clientSideId.length == 0) {
        clientSideId = [WMUIDGenerator generateUID];
    }
    
    NSMutableDictionary *params = [NSMutableDictionary new];
    params[@"action"] = @"chat.start";
    if (pageID.length > 0) {
        params[@"page-id"] = pageID;
    }
    if (clientSideId.length > 0) {
        params[@"client-side-id"] = clientSideId;
    }
    
    [client_ postPath:APIActionPath
           parameters:params
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  WMDebugLog(@"Action: start chat - response:\n%@", responseObject);
                  BOOL hasError = [self handleErrorInResponse:responseObject];
                  CALL_BLOCK(block, !hasError);
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  WMDebugLog(@"Action: start chat - error: %@", error);
                  [self processErrorAPIResponse:operation
                                          error:error];
                  CALL_BLOCK(block, NO);
              }];
    
    return clientSideId;
}

- (NSString *)startChat:(WMResponseCompletionBlock)block {
    return [self startChatWithClientSideId:nil
                           completionBlock:block];
}

- (void)closeChat:(WMResponseCompletionBlock)block {
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(block, NO);
        
        return;
    }
    
    NSDictionary *params = @{
                             @"page-id": pageID,
                             @"action": @"chat.close",
                             };
    
    [client_ postPath:APIActionPath
           parameters:params
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  WMDebugLog(@"Action: close chat - response:\n%@", responseObject);
                  BOOL hasError = [self handleErrorInResponse:responseObject];
                  CALL_BLOCK(block, !hasError);
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  WMDebugLog(@"Action: close chat - error: %@", error);
                  [self processErrorAPIResponse:operation error:error];
                  CALL_BLOCK(block, NO);
              }];
}

- (void)markChatAsRead:(WMResponseCompletionBlock)block {
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(block, NO);
        
        return;
    }
    
    NSDictionary *params = @{
                             @"page-id": pageID,
                             @"action": @"chat.read_by_visitor",
                             };
    
    [client_ postPath:APIActionPath
           parameters:params
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  WMDebugLog(@"Action: close chat - response:\n%@", responseObject);
                  BOOL hasError = [self handleErrorInResponse:responseObject];
                  CALL_BLOCK(block, !hasError);
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  WMDebugLog(@"Action: close chat - error: %@", error);
                  [self processErrorAPIResponse:operation
                                          error:error];
                  CALL_BLOCK(block, NO);
              }];
}


// MARK: - Messages methods

// Full implementation
- (NSString *)sendMessage:(NSString *)message
         withClientSideId:(NSString *)clientSideId
           isHintQuestion:(BOOL)isHintQuestion
             successBlock:(void (^)(NSString *))successBlock
             failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    NSMutableDictionary *parameters = [self baseMessageParametersDictionaryWithMessage:message
                                                                       andClientSideId:clientSideId];
    
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(failureBlock, nil, WMSessionErrorNotConfigured);
        return nil;
    } else {
        parameters[@"page-id"] = pageID;
    }
    
    parameters[@"hint_question"] = isHintQuestion ? @"true" : @"false";
    
    [self postMessageWithParameters:parameters
                    andClientSideId:clientSideId
                       successBlock:successBlock
                       failureBlock:failureBlock];
    
    return clientSideId;
}

// Implementation without clientSideId passed
- (NSString *)sendMessage:(NSString *)message
           isHintQuestion:(BOOL)isHintQuestion
             successBlock:(void (^)(NSString *))successBlock
             failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    return [self sendMessage:message
            withClientSideId:nil
              isHintQuestion:isHintQuestion
                successBlock:successBlock
                failureBlock:failureBlock];
}

// Implementation without isHintQuestion flag passed
- (NSString *)sendMessage:(NSString *)message
         withClientSideId:(NSString *)clientSideId
             successBlock:(void (^)(NSString *))successBlock
             failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    NSMutableDictionary *parameters = [self baseMessageParametersDictionaryWithMessage:message
                                                                       andClientSideId:clientSideId];
    
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(failureBlock, nil, WMSessionErrorNotConfigured);
        return nil;
    } else {
        parameters[@"page-id"] = pageID;
    }
    
    [self postMessageWithParameters:parameters
                    andClientSideId:clientSideId
                       successBlock:successBlock
                       failureBlock:failureBlock];
    
    return clientSideId;
}

// Implementation without clientSideId and isHintQuestion flag passed
- (NSString *)sendMessage:(NSString *)message
             successBlock:(void (^)(NSString *))successBlock
             failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    return [self sendMessage:message
            withClientSideId:nil
                successBlock:successBlock
                failureBlock:failureBlock];
}

- (NSMutableDictionary *)baseMessageParametersDictionaryWithMessage:(NSString *)message
                                                    andClientSideId:(NSString *)clientSideId {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    
    parameters[@"action"] = @"chat.message";
    if (message.length > 0) {
        parameters[@"message"] = message;
    }
    if (clientSideId.length > 0) {
        parameters[@"client-side-id"] = clientSideId;
    }
    
    return parameters;
}

- (void)postMessageWithParameters:(NSDictionary *)parameters
                  andClientSideId:(NSString *)clientSideId
                     successBlock:(void (^)(NSString *))successBlock
                     failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    if (clientSideId.length == 0) {
        clientSideId = [WMUIDGenerator generateUID];
    }
    
    [client_ postPath:APIActionPath
           parameters:parameters
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  WMDebugLog(@"Action: send message - response:\n%@", responseObject);
                  
                  WMSessionError error = WMSessionErrorUnknown;
                  BOOL hasError = [self handleErrorInResponse:responseObject
                                                        error:&error];
                  if (hasError) {
                      CALL_BLOCK(failureBlock, clientSideId, error);
                  } else {
                      CALL_BLOCK(successBlock, clientSideId);
                  }
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  WMDebugLog(@"Action: send message - error: %@", error);
                  
                  [self processErrorAPIResponse:operation
                                          error:error];
                  
                  CALL_BLOCK(failureBlock, clientSideId, WMSessionErrorNetworkError);
              }];
}


// MARK: File (general case)

- (NSString *)sendFile:(NSData *)fileData
                  name:(NSString *)fileName
              mimeType:(NSString *)mimeType
      withClientSideId:(NSString *)clientSideId
          successBlock:(void (^)(NSString *))succcessBlock
          failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    if (clientSideId.length == 0) {
        clientSideId = [WMUIDGenerator generateUID];
    }
    
    NSDictionary *storeData = [self unarchiveClientData];
    NSString *pageID = storeData[WMStorePageIDKey];
    if (pageID.length == 0) {
        CALL_BLOCK(failureBlock, nil, WMSessionErrorNotConfigured);
        
        return nil;
    }
    
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if (pageID.length > 0) {
        params[@"page-id"] = pageID;
    }
    if (clientSideId.length > 0) {
        params[@"client-side-id"] = clientSideId;
    }
    
    void (^multipartConstructBlock)(id<AFMultipartFormData>) = ^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFileData:fileData
                                    name:@"webim_upload_file"
                                fileName:fileName
                                mimeType:mimeType];
    };
    
    NSMutableURLRequest *request = [client_ multipartFormRequestWithMethod:@"POST"
                                                                      path:APIUploadPath
                                                                parameters:params
                                                 constructingBodyWithBlock:multipartConstructBlock];
    AFHTTPRequestOperation *operation = [client_ HTTPRequestOperationWithRequest:request
                                                                         success:^(AFHTTPRequestOperation *operation, id responseObject) {
                                                                             WMSessionError error = 0;
                                                                             BOOL hasError = [self handleErrorInResponse:responseObject
                                                                                                                   error:&error];
                                                                             if (hasError) {
                                                                                 CALL_BLOCK(failureBlock, clientSideId, error);
                                                                             } else {
                                                                                 CALL_BLOCK(succcessBlock, clientSideId);
                                                                             }
                                                                         } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                                                                             CALL_BLOCK(failureBlock, clientSideId, WMSessionErrorNetworkError);
                                                                         }];
    [client_ enqueueHTTPRequestOperation:operation];
    
    return clientSideId;
}

- (void)enqueueHTTPRequestOperation:(id)operation {
    [client_ enqueueHTTPRequestOperation:operation];
}

- (NSString *)sendFile:(NSData *)fileData
                  name:(NSString *)fileName
              mimeType:(NSString *)mimeType
          successBlock:(void (^)(NSString *))succcessBlock
          failureBlock:(void (^)(NSString *, WMSessionError))failureBlock {
    return [self sendFile:fileData
                     name:fileName
                 mimeType:mimeType
         withClientSideId:nil
             successBlock:succcessBlock
             failureBlock:failureBlock];
}


// MARK: Image

- (void)sendImage:(NSData *)imageData
             type:(WMChatAttachmentImageType)type
       completion:(WMResponseCompletionBlock)block {
    NSString *mimeType = type == WMChatAttachmentImageJPEG ? @"image/jpeg" : @"image/png";
    NSString *fileName = type == WMChatAttachmentImageJPEG ? @"ios_file.jpg" : @"ios_file.png";
    
    [self sendFile:imageData
              name:fileName
          mimeType:mimeType
      successBlock:^(NSString *messageID) {
          CALL_BLOCK(block, YES);
      } failureBlock:^(NSString *messageID, WMSessionError error) {
          CALL_BLOCK(block, NO);
      }];
}


- (void)setComposingMessage:(BOOL)isComposing
                      draft:(NSString *)draft {
    lastComposedCachedIsTyping_ = isComposing;
    lastComposedCachedDraft_ = draft;
    
    if (composingTimer_ != nil) {
        return;
    }
    
    // MARK: TODO: Kill the magic number 2
    if ((lastComposedSentDate_ != nil) &&
        ([[NSDate date] timeIntervalSinceDate:lastComposedSentDate_] < 2.f)) {
        composingTimer_ = [NSTimer scheduledTimerWithTimeInterval:2
                                                           target:self
                                                         selector:@selector(setComposingByTimer:)
                                                         userInfo:nil
                                                          repeats:NO];
        
        return;
    }
    
    [self setComposingMessage:isComposing
                        draft:draft
                      isTimer:NO];
}

- (void)setComposingByTimer:(NSTimer *)timer {
    composingTimer_ = nil;
    [self setComposingMessage:lastComposedCachedIsTyping_
                        draft:lastComposedCachedDraft_
                      isTimer:YES];
}

- (void)setComposingMessage:(BOOL)isComposing
                      draft:(NSString *)draft
                    isTimer:(BOOL)isTimer {
    BOOL draftChanged = [self draftChanged:draft];
    
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0) {
        return;
    }
    
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"action"] = @"chat.visitor_typing";
    params[@"page-id"] = pageID;
    params[@"typing"] = isComposing ? @"true" : @"false";
    if (draftChanged) {
        if (draft.length > 0) {
            params[@"message-draft"] = draft;
        } else {
            params[@"del-message-draft"] = @"true";
        }
        lastComposedSentDraft_ = draft;
    }
    
    [client_ postPath:APIActionPath
           parameters:params
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  [self handleErrorInResponse:responseObject];
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  [self processErrorAPIResponse:operation
                                          error:error];
              }];
    
    lastComposedSentDate_ = [NSDate date];
}

- (BOOL)draftChanged:(NSString *)draft {
    if ((lastComposedSentDraft_.length == 0) &&
        (draft.length == 0)) {
        return NO;
    } else if (((lastComposedSentDraft_.length == 0) && (draft.length > 0)) ||
               ((lastComposedSentDraft_.length > 0) && (draft.length == 0))) {
        return YES;
    } else {
        return ![lastComposedSentDraft_ isEqualToString:draft];
    }
}


// MARK: - Rate operator method

- (void)rateOperator:(NSString *)authorID
            withRate:(WMOperatorRate)rate
          completion:(WMResponseCompletionBlock)block {
    NSDictionary *storedValues = [self unarchiveClientData];
    NSString *pageID = storedValues[WMStorePageIDKey];
    NSString *visitSessionID = storedValues[WMStoreVisitSessionIDKey];
    
    if ((pageID.length == 0) ||
        (visitSessionID.length == 0) ||
        (authorID.length == 0)) {
        CALL_BLOCK(block, NO);
        
        return;
    }
    
    NSInteger rateInt = (NSInteger)rate;
    NSAssert((-2 <= rateInt) && (rateInt <= 2), @"Out of rage value for rate: %ld", (long)rate);
    
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"action"] = @"chat.operator_rate_select";
    params[@"rate"] = @(rateInt);
    params[@"operator-id"] = authorID;
    params[@"page-id"] = pageID;
    params[@"visit-session-id"] = visitSessionID;
    
    [client_ postPath:APIActionPath
           parameters:params
              success:^(AFHTTPRequestOperation *operation, id responseObject) {
                  BOOL hasError = [self handleErrorInResponse:responseObject];
                  CALL_BLOCK(block, hasError);
              } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                  [self processErrorAPIResponse:operation
                                          error:error];
                  CALL_BLOCK(block, NO);
              }];
}


// MARK: - Token methods

- (void)tryToSetupPushToken {
    if (sessionStarted_ &&
        !sessionEstablished_) {
        [self performSelector:@selector(tryToSetupPushToken)
                   withObject:nil
                   afterDelay:3];
    } else if (sessionEstablished_) {
        NSString *pushToken = [[NSUserDefaults standardUserDefaults] valueForKey:@"WMDeviceTokenKey"];
        [self setupPushToken:pushToken
                  completion:nil];
    }
}

- (void)setDeviceToken:(NSData *)deviceToken
            completion:(WMResponseCompletionBlock)block {
    NSString *tokenString = [[self class] deviceTokenStringFromData:deviceToken];
    [self setupPushToken:tokenString
              completion:block];
}

+ (void)setDeviceToken:(NSData *)deviceToken {
    NSString *token = [[self class] deviceTokenStringFromData:deviceToken];
    [WMSession setDeviceTokenString:token];
}

+ (NSString *)deviceTokenStringFromData:(NSData *)deviceToken {
    NSCharacterSet *matchSet = [NSCharacterSet characterSetWithCharactersInString:@"<>"];
    NSString *token = [[deviceToken description] stringByTrimmingCharactersInSet:matchSet];
    token = [token stringByReplacingOccurrencesOfString:@" "
                                             withString:@""];
    
    return token;
}

+ (void)setDeviceTokenString:(NSString *)token {
    [[NSUserDefaults standardUserDefaults] setValue:token
                                             forKey:@"WMDeviceTokenKey"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter postNotificationName:@"WMDeviceTokenNotification"
                                      object:token
                                    userInfo:nil];
}


- (void)setupPushToken:(NSString *)pushToken completion:(WMResponseCompletionBlock)block {
    NSString *pageID = [self unarchiveClientData][WMStorePageIDKey];
    if (pageID.length == 0 || pushToken.length == 0) {
        return;
    }
    
    NSDictionary *params =
    @{
      @"page-id": pageID,
      @"action": @"set_push_token",
      @"push-token": pushToken,
      @"platform": @"ios",
      };
    [client_ postPath:APIActionPath parameters:params success:^(AFHTTPRequestOperation *operation, id responseObject) {
        WMDebugLog(@"Action: setup push token - response:\n%@", responseObject);
        if ([self handleErrorInResponse:responseObject]) {
            CALL_BLOCK(block, NO);
        } else {
            CALL_BLOCK(block, YES);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        WMDebugLog(@"Action: setup push token - error: %@", error);
        [self processErrorAPIResponse:operation error:error];
        CALL_BLOCK(block, NO);
    }];
}


// MARK: - Processors

- (void)processGetInitialDelta:(id)response {
    if (response == nil ||
        ![response isKindOfClass:[NSDictionary class]] ||
        ((NSDictionary *)response).count == 0) {
        return;
    }
    
    if (self.isStopped) {
        return;
    }
    
    self.revision = response[@"revision"];
    
    NSMutableDictionary *fullUpdate = response[@"fullUpdate"];
    NSAssert([fullUpdate isKindOfClass:[NSDictionary class]], @"Unexpected result for initial delta");
    
    [self processDeltaFullUpdate:fullUpdate];
}

- (void)processGetDelta:(id)response {
    if ((response == nil) ||
        ![response isKindOfClass:[NSDictionary class]] ||
        ((NSDictionary *)response).count == 0) {
        return;
    }
    
    if (self.isStopped) {
        return;
    }
    
    self.revision = response[@"revision"];
    
    WMDebugLog(@"Received delta at %@ revision", self.revision);
    
    [self processDeltaFullUpdate:response[@"fullUpdate"]];
    [self processDeltaDeltaList:response[@"deltaList"]];
}

- (void)processDeltaFullUpdate:(NSMutableDictionary *)updateDictionary {
    lastFullUpdateDate_ = [NSDate date];
    
    if (patchDeltaTimer_ == nil) {
        patchDeltaTimer_ = [NSTimer scheduledTimerWithTimeInterval:PatchTimerCheckTimeInterval
                                                            target:self
                                                          selector:@selector(patchOnlineDelta)
                                                          userInfo:nil
                                                           repeats:YES];
    }
    
    if ((updateDictionary == nil) ||
        ![updateDictionary isKindOfClass:[NSDictionary class]]) {
        return;
    }
    
    NSMutableDictionary *storeValues = [NSMutableDictionary dictionary];
    storeValues[WMStoreVisitorKey] = updateDictionary[@"visitor"];
    storeValues[WMStoreVisitSessionIDKey] = updateDictionary[@"visitSessionId"];
    storeValues[WMStorePageIDKey] = updateDictionary[@"pageId"];
    storeValues[WMStoreAreHintsEnabled] = ([[updateDictionary allKeys] containsObject:@"hintsEnabled"])? updateDictionary[@"hintsEnabled"] : @0; // This checking exists for reverse compability
    storeValues[WMStoreVisitorExtKey] = userDefinedVisitorFields_;
    
    if (self.isStopped) {
        return;
    }
    
    [self archiveClientData:storeValues];
    
    self.onlineStatus = [self onlineStatusFromString:updateDictionary[@"onlineStatus"]];
    [self updateSessionStateWithObject:updateDictionary[@"state"]];
    [self updateChatWithObject:updateDictionary[@"chat"]];
    
    if ([_delegate respondsToSelector:@selector(sessionDidReceiveFullUpdate:)]) {
        [_delegate sessionDidReceiveFullUpdate:self];
    }
}

- (void)patchOnlineDelta {
    if (self.isStopped) {
        return;
    }
    
    if ([[NSDate date] timeIntervalSinceDate:lastFullUpdateDate_] > OnlineDeltaPatchTimeInterval) {
        if ((_chat == nil) ||
            (_chat.state == WMChatStateClosed) ||
            (_chat.state == WMChatStateClosedByVisitor)) {
            // Main window presented
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(startGettingDeltaWithComet)
                                                       object:nil];
            [self cancelGettingDeltaWithComet];
            self.revision = @0;
            activeDeltaRevisionNumber_ = nil;
            
            [self startGettingDeltaWithComet];
        }
    }
}

- (void)archiveClientData:(NSDictionary *)dictionary {
    if(isMultiUser_) {
        [NSUserDefaults archiveClientDataMU:userId_
                                 dictionary:dictionary];
    } else {
        [NSUserDefaults archiveClientData:dictionary];
    }
}

- (WMSessionOnlineStatus)onlineStatusFromString:(NSString *)status {
    NSDictionary *map = @{
                          @"online": @(WMSessionOnlineStatusOnline),
                          @"busy_online": @(WMSessionOnlineStatusBusyOnline),
                          @"offline": @(WMSessionOnlineStatusOffline),
                          @"busy_offline": @(WMSessionOnlineStatusBusyOffline),
                          };
    if (status.length == 0 ||
        map[status] == nil) {
        return WMSessionOnlineStatusUnknown;
    }
    
    return (WMSessionOnlineStatus)[map[status] integerValue];
}

- (void)updateSessionStateWithObject:(NSDictionary *)object {
    NSParameterAssert([object isKindOfClass:[NSString class]]);
    
    _state = [self sesstionStateFromString:(NSString *)object];
    
#if 1
    // Currently we have no chance to get fullDelta on changes in operator offline/online status,
    // so manually change this flag according to the session status
    if (_state == WMSessionStateOfflineMessage) {
        self.onlineStatus = WMSessionOnlineStatusOffline;
        // Close current offline chat to avoid conflicts in future
        [self closeChat:nil];
    }
#endif
    
    if ([_delegate respondsToSelector:@selector(sessionDidChangeStatus:)]) {
        [_delegate sessionDidChangeStatus:self];
    }
}

- (WMSessionState)sesstionStateFromString:(NSString *)state {
    if ([@"idle" isEqualToString:state]) {
        return WMSessionStateIdle;
    }
    
    if ([@"idle-after-chat" isEqualToString:state]) {
        return WMSessionStateIdleAfterChat;
    }
    
    if ([@"chat" isEqualToString:state]) {
        return WMSessionStateChat;
    }
    
    if ([@"offline-message" isEqualToString:state]) {
        return WMSessionStateOfflineMessage;
    }
    
    return WMSessionStateUnknown;
}

- (void)updateChatWithObject:(NSDictionary *)object {
    if ([object isKindOfClass:[NSNull class]]) {
        _chat = nil;
    } else {
        if (_chat == nil) {
            _chat = [WMChat new];
        }
        
        [_chat initWithObject:object
                   forSession:self];
        if ([_delegate respondsToSelector:@selector(session:didStartChat:)]) {
            [_delegate session:self
                  didStartChat:_chat];
        }
    }
}

- (void)processDeltaDeltaList:(NSDictionary *)deltaList {
    if (deltaList == nil ||
        ![deltaList isKindOfClass:[NSArray class]]) {
        return;
    }
    
    for (NSDictionary *deltaDictionary in deltaList) {
        NSString *objectTypeString = deltaDictionary[@"objectType"];
        NSString *eventString = deltaDictionary[@"event"];
        NSMutableDictionary *dataDictionary = deltaDictionary[@"data"];
        
        // MARK: TODO: Refactor this!
        if ([@"VISIT_SESSION_STATE" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateSessionStateWithObject:dataDictionary];
            } else {
                WMDebugLog(@"Warning: %@ is not expected for %@", eventString, objectTypeString);
            }
        } else if ([@"CHAT" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateChatWithObject:dataDictionary];
            } else {
                WMDebugLog(@"Warning: %@ is not expected for %@", eventString, objectTypeString);
            }
        } else if ([@"CHAT_MESSAGE" isEqualToString:objectTypeString]) {
            if ([@"add" isEqualToString:eventString]) {
                [self addChatMessageFromObject:dataDictionary];
            } else {
                WMDebugLog(@"Warning: %@ is not expected for %@", eventString, objectTypeString);
            }
        } else if ([@"CHAT_STATE" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateChatStatusWithObject:dataDictionary];
            } else {
                WMDebugLog(@"Warning: %@ is not expected for %@", eventString, objectTypeString);
            }
        } else if ([@"CHAT_OPERATOR" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateChatOperatorWithObject:dataDictionary];
            } else {
                WMDebugLog(@"Warning: %@ is not expected for %@", eventString, objectTypeString);
            }
        } else if ([@"CHAT_READ_BY_VISITOR" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateChatReadByVisitorWithObject:dataDictionary];
            }
        } else if ([@"CHAT_OPERATOR_TYPING" isEqualToString:objectTypeString]) {
            if ([@"upd" isEqualToString:eventString]) {
                [self updateChatOperatorTypingWithObject:dataDictionary];
            }
        } else {
            WMDebugLog(@"Warning: ProcessDelta: uncotegorized object %@:\n%@",
                       objectTypeString, deltaDictionary);
        }
    }
}

- (void)addChatMessageFromObject:(NSDictionary *)object {
    NSAssert(_chat != nil, @"Chat is not initialized");
    
    WMMessage *newMessage = [[WMMessage alloc] initWithObject:object
                                                   forSession:self];
    [_chat.messages addObject:newMessage];
    if ([_delegate respondsToSelector:@selector(session:didReceiveMessage:)]) {
        [_delegate session:self
         didReceiveMessage:newMessage];
    }
}

- (void)updateChatStatusWithObject:(NSDictionary *)object {
    NSParameterAssert([object isKindOfClass:[NSString class]]);
    if (_chat == nil) {
        // That ugly feeling...
        return;
    }
    
    _chat.state = [_chat chatStateFromString:(NSString *)object];
    if ([_delegate respondsToSelector:@selector(sessionDidChangeChatStatus:)]) {
        [_delegate sessionDidChangeChatStatus:self];
    }
}

- (void)updateChatOperatorWithObject:(NSDictionary *)object {
    NSAssert(_chat != nil, @"Chat object must exist before adding operator");
    
    if (object == nil ||
        [object isKindOfClass:[NSNull class]]) {
        _chat.chatOperator = nil;
    } else {
        if (_chat.chatOperator == nil) {
            _chat.chatOperator = [[WMOperator alloc] initWithObject:object];
        } else {
            [_chat.chatOperator updateWithObject:object];
        }
    }
    
    if ([_delegate respondsToSelector:@selector(session:didUpdateOperator:)]) {
        [_delegate session:self
         didUpdateOperator:_chat.chatOperator];
    }
}

- (void)updateChatReadByVisitorWithObject:(id)object {
    BOOL chatReadByVisitor = [object boolValue];
    _chat.hasUnreadMessages = !chatReadByVisitor;
}

- (void)updateChatOperatorTypingWithObject:(id)object {
    BOOL operatorTyping = [object boolValue];
    _chat.operatorTyping = operatorTyping;
    if ([_delegate respondsToSelector:@selector(session:didChangeOperatorTyping:)]) {
        [_delegate session:self
   didChangeOperatorTyping:operatorTyping];
    }
}


// MARK: Error processors

- (void)processErrorAPIResponse:(AFHTTPRequestOperation *)operation
                          error:(NSError *)error {
    if (operation.response == nil) {
        // Network problem
        [self postponeGettingDelta];
        
        if ([_delegate respondsToSelector:@selector(session:didReceiveError:)]) {
            [_delegate session:self
               didReceiveError:WMSessionErrorNetworkError];
        }
    }
}

- (void)postponeGettingDelta {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(startGettingDeltaWithComet)
                                               object:nil];
    [self performSelector:@selector(startGettingDeltaWithComet)
               withObject:nil
               afterDelay:ReconnectTimeInterval];
}

- (BOOL)handleErrorInResponse:(NSDictionary *)response
                        error:(WMSessionError *)error {
    if ((response != nil) &&
        [response isKindOfClass:[NSDictionary class]] &&
        (response[@"error"] != nil)) {
        [self cancelGettingDeltaWithComet];
        
        if (self.isStopped) {
            return NO;
        }
        
        WMSessionError errorID = [self errorFromString:response[@"error"]];
        if (error != NULL) {
            *error = errorID;
        }
        
        if ([_delegate respondsToSelector:@selector(session:didReceiveError:)]) {
            if (errorID == WMSessionErrorReinitRequired) {
                NSMutableDictionary *storage = [[self unarchiveClientData] mutableCopy];
                [storage removeObjectForKey:WMStorePageIDKey];
                [self archiveClientData:storage];
                
                activeDeltaRevisionNumber_ = nil;
                sessionEstablished_ = NO;
                [self performSelector:@selector(startGettingDeltaWithComet)
                           withObject:nil
                           afterDelay:0.1];
            }
            [_delegate session:self didReceiveError:errorID];
        }
        
        return YES;
    }
    
    return NO;
}

- (BOOL)handleErrorInResponse:(NSDictionary *)response {
    return [self handleErrorInResponse:response
                                 error:nil];
}

- (WMSessionError)errorFromString:(NSString *)errorDescription {
    if ([@"reinit-required" isEqualToString:errorDescription]) {
        return WMSessionErrorReinitRequired;
    }
    
    if ([@"server-not-ready" isEqualToString:errorDescription]) {
        return WMSessionErrorServerNotReady;
    }
    
    if ([@"account-blocked" isEqualToString:errorDescription]) {
        return WMSessionErrorAccountBlocked;
    }
    
    if ([@"not_allowed_file_type" isEqualToString:errorDescription]) {
        return WMSessionErrorAttachmentTypeNotAllowed;
    }
    
    if ([@"max_file_size_exceeded" isEqualToString:errorDescription]) {
        return WMSessionErrorAttachmentSizeExceeded;
    }
    
    if ([@"max-message-length-exceeded" isEqualToString:errorDescription]) {
        return WMSessionErrorMessageSizeExceeded;
    }
    
    if ([@"chat_count_limit_exceeded" isEqualToString:errorDescription]) {
        return WMSessionErrorChatCountLimitExceeded;
    }
    
    if ([@"visitor_banned" isEqualToString:errorDescription]) {
        return WMSessionErrorVisitorBanned;
    }
    
    if ([@"chat_count_limit_exceeded" isEqualToString:errorDescription]) {
        return WMSessionErrorChatCountLimitExceeded;
    }
    
    return WMSessionErrorUnknown;
}


// MARK: - UIApplication Notifications

- (void)applicationDidBecomeActiveNotification:(NSNotification *)notification {
    if (sessionStarted_ && !gettingInitialDelta_) {
#if 1
        self.revision = @0;
        // Reset revision to obtain fullUpdate (to be replaced when we'll get delta for changing
        // offline/online status for operators
#endif
        if (self.isStopped) {
            return;
        }
        
        [self continueInLocation];
    }
}

- (void)continueInLocation {
    [self cancelGettingDeltaWithComet];
    
    [self performSelector:@selector(startGettingDeltaWithComet)
               withObject:nil
               afterDelay:0.3];
}

- (void)applicationDidEnterBackgroundNotification:(NSNotification *)notification {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(startGettingDeltaWithComet)
                                               object:nil];
    [self cancelGettingDeltaWithComet];
}

- (void)enableObservingForNotifications:(BOOL)enable {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    if (enable) {
        [notificationCenter addObserver:self
                               selector:@selector(applicationDidBecomeActiveNotification:)
                                   name:UIApplicationDidBecomeActiveNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(applicationDidEnterBackgroundNotification:)
                                   name:UIApplicationDidEnterBackgroundNotification
                                 object:nil];
        [notificationCenter addObserver:self
                               selector:@selector(deviceTokenNotification:)
                                   name:@"WMDeviceTokenNotification"
                                 object:nil];
    } else {
        [notificationCenter removeObserver:self
                                      name:UIApplicationDidBecomeActiveNotification
                                    object:nil];
        [notificationCenter removeObserver:self
                                      name:UIApplicationDidEnterBackgroundNotification
                                    object:nil];
        [notificationCenter removeObserver:self
                                      name:@"WMDeviceTokenNotification"
                                    object:nil];
    }
}

- (void)deviceTokenNotification:(NSNotification *)notification {
    [self tryToSetupPushToken];
}


// MARK: -

- (void)setOnlineStatus:(WMSessionOnlineStatus)onlineStatus {
    static NSString *name = @"onlineOperator";
    [self willChangeValueForKey:name];
    _onlineStatus = onlineStatus;
    [self didChangeValueForKey:name];
    
    if ([_delegate respondsToSelector:@selector(session:didChangeOnlineStatus:)]) {
        [_delegate session:self didChangeOnlineStatus:onlineStatus];
    }
}

- (void)setLocation:(NSString *)location {
    [super setLocation:location];
    
    if (sessionStarted_) {
        [self cancelGettingDeltaWithComet];
        [self startSession:nil];
    }
}

- (NSString *)percentEscapeString:(NSString *)string {
    NSString *result = CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                                 (CFStringRef)string,
                                                                                 (CFStringRef)@" ",
                                                                                 (CFStringRef)@":/?@!$&'()*+,;=",
                                                                                 kCFStringEncodingUTF8));
    return [result stringByReplacingOccurrencesOfString:@" " withString:@"+"];
}

- (void)clearCachedUserData {
    [self archiveClientData:nil];
    self.revision = nil;
}

@end
