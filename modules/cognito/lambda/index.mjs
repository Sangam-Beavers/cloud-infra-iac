// Pre-Token Generation 트리거 (V3): ID 토큰 + ACCESS 토큰 둘 다에 public_id를 넣는다.
// custom:public_id (DB 공개 식별자)를 토큰 클레임으로 승격해 백엔드가 sub 대신 이걸 쓴다.
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
