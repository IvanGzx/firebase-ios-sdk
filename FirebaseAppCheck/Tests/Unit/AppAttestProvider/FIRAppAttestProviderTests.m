/*
 * Copyright 2021 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#import "FBLPromise+Testing.h"
#import "OCMock.h"

#import "FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRAppAttestProvider.h"

#import "FirebaseAppCheck/Sources/AppAttestProvider/API/FIRAppAttestAPIService.h"
#import "FirebaseAppCheck/Sources/AppAttestProvider/FIRAppAttestService.h"
#import "FirebaseAppCheck/Sources/AppAttestProvider/Storage/FIRAppAttestArtifactStorage.h"
#import "FirebaseAppCheck/Sources/AppAttestProvider/Storage/FIRAppAttestKeyIDStorage.h"
#import "FirebaseAppCheck/Sources/Core/Errors/FIRAppCheckErrorUtil.h"
#import "FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRAppCheckToken.h"
#import "FirebaseAppCheck/Sources/AppAttestProvider/API/FIRAppAttestInitialHandshakeResponse.h"

#import "FirebaseCore/Sources/Private/FirebaseCoreInternal.h"

// Currently FIRAppAttestProvider is available only on iOS.
#if TARGET_OS_IOS

@interface FIRAppAttestProvider (Tests)
- (instancetype)initWithAppAttestService:(id<FIRAppAttestService>)appAttestService
                              APIService:(id<FIRAppAttestAPIServiceProtocol>)APIService
                            keyIDStorage:(id<FIRAppAttestKeyIDStorageProtocol>)keyIDStorage
                         artifactStorage:(id<FIRAppAttestArtifactStorageProtocol>)artifactStorage;
@end

API_AVAILABLE(ios(14.0))
@interface FIRAppAttestProviderTests : XCTestCase

@property(nonatomic) FIRAppAttestProvider *provider;

@property(nonatomic) OCMockObject<FIRAppAttestService> *mockAppAttestService;
@property(nonatomic) OCMockObject<FIRAppAttestAPIServiceProtocol> *mockAPIService;
@property(nonatomic) OCMockObject<FIRAppAttestKeyIDStorageProtocol> *mockStorage;
@property(nonatomic) OCMockObject<FIRAppAttestArtifactStorageProtocol> *mockArtifactStorage;

@end

@implementation FIRAppAttestProviderTests

- (void)setUp {
  [super setUp];

  self.mockAppAttestService = OCMProtocolMock(@protocol(FIRAppAttestService));
  self.mockAPIService = OCMProtocolMock(@protocol(FIRAppAttestAPIServiceProtocol));
  self.mockStorage = OCMProtocolMock(@protocol(FIRAppAttestKeyIDStorageProtocol));
  self.mockArtifactStorage = OCMProtocolMock(@protocol(FIRAppAttestArtifactStorageProtocol));

  self.provider = [[FIRAppAttestProvider alloc] initWithAppAttestService:self.mockAppAttestService
                                                              APIService:self.mockAPIService
                                                            keyIDStorage:self.mockStorage
                                                         artifactStorage:self.mockArtifactStorage];
}

- (void)tearDown {
  self.provider = nil;
  self.mockArtifactStorage = nil;
  self.mockStorage = nil;
  self.mockAPIService = nil;
  self.mockAppAttestService = nil;
}

- (void)testInitWithValidApp {
  FIROptions *options = [[FIROptions alloc] initWithGoogleAppID:@"app_id" GCMSenderID:@"sender_id"];
  options.APIKey = @"api_key";
  options.projectID = @"project_id";
  FIRApp *app = [[FIRApp alloc] initInstanceWithName:@"testInitWithValidApp" options:options];

  XCTAssertNotNil([[FIRAppAttestProvider alloc] initWithApp:app]);
}

- (void)testGetTokenWhenAppAttestIsNotSupported {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(NO)];

  // 2. Don't expect other operations.
  OCMReject([self.mockStorage getAppAttestKeyID]);
  OCMReject([self.mockAppAttestService generateKeyWithCompletionHandler:OCMOCK_ANY]);
  OCMReject([self.mockArtifactStorage getArtifact]);
  OCMReject([self.mockAPIService getRandomChallenge]);
  OCMReject([self.mockStorage setAppAttestKeyID:OCMOCK_ANY]);
  OCMReject([self.mockAppAttestService attestKey:OCMOCK_ANY
                                  clientDataHash:OCMOCK_ANY
                               completionHandler:OCMOCK_ANY]);
  OCMReject([self.mockAPIService attestKeyWithAttestation:OCMOCK_ANY
                                                    keyID:OCMOCK_ANY
                                                challenge:OCMOCK_ANY]);

  // 3. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertNil(token);
        XCTAssertEqualObjects(
            error, [FIRAppCheckErrorUtil unsupportedAttestationProvider:@"AppAttestProvider"]);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 4. Verify mocks.
  [self verifyAllMocks];
}

- (void)testGetToken_WhenNoExistingKey_Success {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(YES)];

  // 2. Expect storage getAppAttestKeyID.
  FBLPromise *rejectedPromise = [FBLPromise pendingPromise];
  NSError *error = [NSError errorWithDomain:@"testGetToken_WhenNoExistingKey_Success"
                                       code:NSNotFound
                                   userInfo:nil];
  [rejectedPromise reject:error];
  OCMExpect([self.mockStorage getAppAttestKeyID]).andReturn(rejectedPromise);

  // 3. Expect App Attest key to be generated.
  NSString *generatedKeyID = @"generatedKeyID";
  id completionArg = [OCMArg invokeBlockWithArgs:generatedKeyID, [NSNull null], nil];
  OCMExpect([self.mockAppAttestService generateKeyWithCompletionHandler:completionArg]);

  // 4. Expect the key ID to be stored.
  OCMExpect([self.mockStorage setAppAttestKeyID:generatedKeyID])
      .andReturn([FBLPromise resolvedWith:generatedKeyID]);

  // 5. Expect random challenge to be requested.
  NSData *randomChallenge = [@"random challenge" dataUsingEncoding:NSUTF8StringEncoding];
  OCMExpect([self.mockAPIService getRandomChallenge])
      .andReturn([FBLPromise resolvedWith:randomChallenge]);

  // 6. Expect the key to be attested with the challenge.
  NSData *expectedChallengeHash = [randomChallenge base64EncodedDataWithOptions:0];
  NSData *attestationData = [@"attestation data" dataUsingEncoding:NSUTF8StringEncoding];
  id attestCompletionArg = [OCMArg invokeBlockWithArgs:attestationData, [NSNull null], nil];
  OCMExpect([self.mockAppAttestService attestKey:generatedKeyID
                                  clientDataHash:expectedChallengeHash
                               completionHandler:attestCompletionArg]);

  // 7. Expect key attestation request to be sent.
  FIRAppCheckToken *FACToken = [[FIRAppCheckToken alloc] initWithToken:@"FAC token"
                                                        expirationDate:[NSDate date]];
  NSData *artifactData = [@"attestation artifact" dataUsingEncoding:NSUTF8StringEncoding];
  __auto_type attestKeyResponse = [[FIRAppAttestInitialHandshakeResponse alloc] initWithArtifact:artifactData token:FACToken];
  OCMExpect([self.mockAPIService attestKeyWithAttestation:attestationData
                                                    keyID:generatedKeyID
                                                challenge:randomChallenge])
      .andReturn([FBLPromise resolvedWith:attestKeyResponse]);

  // 8. Expect the artifact received from Firebase backend to be saved.
  OCMExpect([self.mockArtifactStorage setArtifact:artifactData]).andReturn([FBLPromise resolvedWith:artifactData]);

  // 9. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertEqualObjects(token.token, FACToken.token);
        XCTAssertEqualObjects(token.expirationDate, FACToken.expirationDate);
        XCTAssertNil(error);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 10. Verify mocks.
  [self verifyAllMocks];
}

- (void)testGetToken_WhenExistingUnregisteredKey_Success {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(YES)];

  // 2. Expect storage getAppAttestKeyID.
  NSString *existingKeyID = @"existingKeyID";
  OCMExpect([self.mockStorage getAppAttestKeyID])
      .andReturn([FBLPromise resolvedWith:existingKeyID]);

  // 3. Don't expect App Attest key to be generated.
  OCMReject([self.mockAppAttestService generateKeyWithCompletionHandler:OCMOCK_ANY]);

  // 4. Don't expect the key ID to be stored.
  OCMReject([self.mockStorage setAppAttestKeyID:OCMOCK_ANY]);

  // 5. Expect a stored artifact to be requested.
  __auto_type rejectedPromise =
      [self rejectedPromiseWithError:
                [NSError errorWithDomain:@"testGetToken_WhenExistingUnregisteredKey_Success"
                                    code:NSNotFound
                                userInfo:nil]];
  OCMExpect([self.mockArtifactStorage getArtifact]).andReturn(rejectedPromise);

  // 6. Expect random challenge to be requested.
  NSData *randomChallenge = [@"random challenge" dataUsingEncoding:NSUTF8StringEncoding];
  OCMExpect([self.mockAPIService getRandomChallenge])
      .andReturn([FBLPromise resolvedWith:randomChallenge]);

  // 7. Expect the key to be attested with the challenge.
  NSData *expectedChallengeHash = [randomChallenge base64EncodedDataWithOptions:0];
  NSData *attestationData = [@"attestation data" dataUsingEncoding:NSUTF8StringEncoding];
  id attestCompletionArg = [OCMArg invokeBlockWithArgs:attestationData, [NSNull null], nil];
  OCMExpect([self.mockAppAttestService attestKey:existingKeyID
                                  clientDataHash:expectedChallengeHash
                               completionHandler:attestCompletionArg]);

  // 8. Expect key attestation request to be sent.
  FIRAppCheckToken *FACToken = [[FIRAppCheckToken alloc] initWithToken:@"FAC token"
                                                        expirationDate:[NSDate date]];
  NSData *artifactData = [@"attestation artifact" dataUsingEncoding:NSUTF8StringEncoding];
  __auto_type attestKeyResponse = [[FIRAppAttestInitialHandshakeResponse alloc] initWithArtifact:artifactData token:FACToken];
  OCMExpect([self.mockAPIService attestKeyWithAttestation:attestationData
                                                    keyID:existingKeyID
                                                challenge:randomChallenge])
      .andReturn([FBLPromise resolvedWith:attestKeyResponse]);

  // 9. Expect the artifact received from Firebase backend to be saved.
  OCMExpect([self.mockArtifactStorage setArtifact:artifactData]).andReturn([FBLPromise resolvedWith:artifactData]);

  // 10. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertEqualObjects(token.token, FACToken.token);
        XCTAssertEqualObjects(token.expirationDate, FACToken.expirationDate);
        XCTAssertNil(error);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 11. Verify mocks.
  [self verifyAllMocks];
}

- (void)testGetToken_WhenUnregisteredKeyAndRandomChallengeError {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(YES)];

  // 2. Expect storage getAppAttestKeyID.
  NSString *existingKeyID = @"existingKeyID";
  OCMExpect([self.mockStorage getAppAttestKeyID])
      .andReturn([FBLPromise resolvedWith:existingKeyID]);

  // 3. Expect a stored artifact to be requested.
  __auto_type rejectedPromise =
      [self rejectedPromiseWithError:
                [NSError errorWithDomain:@"testGetToken_WhenExistingUnregisteredKey_Success"
                                    code:NSNotFound
                                userInfo:nil]];
  OCMExpect([self.mockArtifactStorage getArtifact]).andReturn(rejectedPromise);

  // 4. Expect random challenge to be requested.
  NSError *challengeError = [NSError errorWithDomain:@"testGetToken_WhenRandomChallengeError"
                                                code:NSNotFound
                                            userInfo:nil];
  OCMExpect([self.mockAPIService getRandomChallenge])
      .andReturn([self rejectedPromiseWithError:challengeError]);

  // 5. Don't expect other steps.
  OCMReject([self.mockStorage setAppAttestKeyID:OCMOCK_ANY]);
  OCMReject([self.mockAppAttestService attestKey:OCMOCK_ANY
                                  clientDataHash:OCMOCK_ANY
                               completionHandler:OCMOCK_ANY]);
  OCMReject([self.mockAPIService attestKeyWithAttestation:OCMOCK_ANY
                                                    keyID:OCMOCK_ANY
                                                challenge:OCMOCK_ANY]);

  // 6. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertNil(token);
        XCTAssertEqualObjects(error, challengeError);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 7. Verify mocks.
  [self verifyAllMocks];
}

- (void)testGetToken_WhenUnregisteredKeyAndKeyAttestationError {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(YES)];

  // 2. Expect storage getAppAttestKeyID.
  NSString *existingKeyID = @"existingKeyID";
  OCMExpect([self.mockStorage getAppAttestKeyID])
      .andReturn([FBLPromise resolvedWith:existingKeyID]);

  // 3. Expect a stored artifact to be requested.
  __auto_type rejectedPromise =
      [self rejectedPromiseWithError:
                [NSError errorWithDomain:@"testGetToken_WhenExistingUnregisteredKey_Success"
                                    code:NSNotFound
                                userInfo:nil]];
  OCMExpect([self.mockArtifactStorage getArtifact]).andReturn(rejectedPromise);

  // 4. Expect random challenge to be requested.
  NSData *randomChallenge = [@"random challenge" dataUsingEncoding:NSUTF8StringEncoding];
  OCMExpect([self.mockAPIService getRandomChallenge])
      .andReturn([FBLPromise resolvedWith:randomChallenge]);

  // 5. Expect the key to be attested with the challenge.
  NSData *expectedChallengeHash = [randomChallenge base64EncodedDataWithOptions:0];
  NSError *attestationError = [NSError errorWithDomain:@"testGetTokenWhenKeyAttestationError"
                                                  code:0
                                              userInfo:nil];
  id attestCompletionArg = [OCMArg invokeBlockWithArgs:[NSNull null], attestationError, nil];
  OCMExpect([self.mockAppAttestService attestKey:existingKeyID
                                  clientDataHash:expectedChallengeHash
                               completionHandler:attestCompletionArg]);

  // 6. Don't exchange API request.
  OCMReject([self.mockAPIService attestKeyWithAttestation:OCMOCK_ANY
                                                    keyID:OCMOCK_ANY
                                                challenge:OCMOCK_ANY]);

  // 7. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertNil(token);
        XCTAssertEqualObjects(error, attestationError);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 8. Verify mocks.
  [self verifyAllMocks];
}

- (void)testGetToken_WhenUnregisteredKeyAndKeyAttestationExchangeError {
  // 1. Expect FIRAppAttestService.isSupported.
  [OCMExpect([self.mockAppAttestService isSupported]) andReturnValue:@(YES)];

  // 2. Expect storage getAppAttestKeyID.
  NSString *existingKeyID = @"existingKeyID";
  OCMExpect([self.mockStorage getAppAttestKeyID])
      .andReturn([FBLPromise resolvedWith:existingKeyID]);

  // 3. Expect a stored artifact to be requested.
  __auto_type rejectedPromise =
      [self rejectedPromiseWithError:
                [NSError errorWithDomain:@"testGetToken_WhenExistingUnregisteredKey_Success"
                                    code:NSNotFound
                                userInfo:nil]];
  OCMExpect([self.mockArtifactStorage getArtifact]).andReturn(rejectedPromise);

  // 4. Expect random challenge to be requested.
  NSData *randomChallenge = [@"random challenge" dataUsingEncoding:NSUTF8StringEncoding];
  OCMExpect([self.mockAPIService getRandomChallenge])
      .andReturn([FBLPromise resolvedWith:randomChallenge]);

  // 5. Expect the key to be attested with the challenge.
  NSData *expectedChallengeHash = [randomChallenge base64EncodedDataWithOptions:0];
  NSData *attestationData = [@"attestation data" dataUsingEncoding:NSUTF8StringEncoding];
  id attestCompletionArg = [OCMArg invokeBlockWithArgs:attestationData, [NSNull null], nil];
  OCMExpect([self.mockAppAttestService attestKey:existingKeyID
                                  clientDataHash:expectedChallengeHash
                               completionHandler:attestCompletionArg]);

  // 6. Expect exchange request to be sent.
  NSError *exchangeError = [NSError errorWithDomain:@"testGetTokenWhenKeyAttestationExchangeError"
                                               code:0
                                           userInfo:nil];
  OCMExpect([self.mockAPIService attestKeyWithAttestation:attestationData
                                                    keyID:existingKeyID
                                                challenge:randomChallenge])
      .andReturn([self rejectedPromiseWithError:exchangeError]);

  // 7. Call get token.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];

        XCTAssertNil(token);
        XCTAssertEqualObjects(error, exchangeError);
      }];

  [self waitForExpectations:@[ completionExpectation ] timeout:0.5];

  // 8. Verify mocks.
  [self verifyAllMocks];
}

// TODO: FAC token refresh tests (b/186438346).

#pragma mark - Helpers

- (FBLPromise *)rejectedPromiseWithError:(NSError *)error {
  FBLPromise *rejectedPromise = [FBLPromise pendingPromise];
  [rejectedPromise reject:error];
  return rejectedPromise;
}

- (void)verifyAllMocks {
  OCMVerifyAll(self.mockAppAttestService);
  OCMVerifyAll(self.mockAPIService);
  OCMVerifyAll(self.mockStorage);
  OCMVerifyAll(self.mockArtifactStorage);
}

@end

#endif  // TARGET_OS_IOS
