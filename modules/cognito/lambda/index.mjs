// Pre-Token Generation 트리거 (V3)입니다. ID 토큰과 ACCESS 토큰 둘 다에 public_id를 넣습니다.
// custom:public_id (DB 공개 식별자)를 토큰 클레임으로 승격해, 백엔드가 sub 대신 이 값을 사용하도록 합니다.
export const handler = async (event) => {
  const publicId = event.request?.userAttributes?.["custom:public_id"];

  if (publicId) {
    event.response = {
      claimsAndScopeOverrideDetails: {
        idTokenGeneration: {
          claimsToAddOrOverride: { public_id: publicId },
        },
        accessTokenGeneration: {
          claimsToAddOrOverride: { public_id: publicId },
        },
      },
    };
  }
  return event;
};
