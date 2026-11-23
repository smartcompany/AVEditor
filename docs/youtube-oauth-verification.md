# YouTube OAuth verification (`aveditor-shorts`)

Project: `aveditor-shorts` (`800175376935`)  
Scope: `https://www.googleapis.com/auth/youtube.upload` only  
Public site / privacy: https://easyclip.coinpang.org/privacy  
Source of privacy pages: [smartcompany/AVEditorServer](https://github.com/smartcompany/AVEditorServer)

## Common rejection: missing data-protection disclosures

Google may reply:

> Your privacy policy does not specify any data protection mechanisms for sensitive data.

**Fix:** the privacy policy must explicitly describe *how* Google user data is protected (not only what is collected). Required language includes encryption / security procedures. Live text lives in `AVEditorServer` → `app/privacy/page.tsx` (section “Data protection mechanisms for Google user data”).

### After updating the policy

1. Merge + deploy `AVEditorServer` so https://easyclip.coinpang.org/privacy shows the new section and effective date.
2. Cloud Console → OAuth consent screen: privacy policy URL stays `https://easyclip.coinpang.org/privacy` (update only if the URL changes).
3. **Reply to the same Google verification email** (required). Review does not continue until you reply.

### Suggested reply to Google

```text
Hello,

We have updated our privacy policy to include data protection disclosures for
sensitive Google user data (encryption in transit, on-device secure storage,
OAuth access control, data minimization, and revocation).

Updated privacy policy:
https://easyclip.coinpang.org/privacy

The OAuth consent screen still uses this same URL. Please continue the
verification for project aveditor-shorts (800175376935).

Thank you,
Yong Geon Kim
gunnylove@gmail.com
```

## Checklist before re-submitting

- [ ] Privacy policy has an explicit data-protection / security section
- [ ] Homepage links to the same privacy URL as the consent screen
- [ ] Only `youtube.upload` is requested (plus Google Sign-In profile/email as needed by the SDK)
- [ ] Demo video (if requested) shows consent screen scopes in English and upload flow
- [ ] Reply sent on the verification email thread after the live page is updated
