# Project TODO

## Host authentication and ownership

### Current decision: anonymous browser sessions

Use an anonymous browser session for hosts during the first version. A host should be able to create and manage games without registering or receiving email.

Required behavior:

- [ ] Give each host browser an unguessable, signed session identifier.
- [ ] Associate every hosted game with the anonymous session that created it.
- [ ] Scope host-only game lookups through the current anonymous session; do not authorize host controls with `Game.find` alone.
- [ ] Keep remote `Player` identity separate from host ownership.
- [ ] Explain in the UI that clearing browser data or changing devices may remove access to anonymously hosted games.
- [ ] Test that one anonymous session cannot view or operate another session's host controls.

This is deliberately temporary. Do not build features that assume anonymous browser ownership is permanent.

### Future required work: passwordless magic-link authentication

Replace anonymous-only ownership with passwordless host accounts inspired by Fizzy's authentication model.

- [ ] Add a persistent host identity with a normalized, validated email address.
- [ ] Add database-backed session records referenced by a signed, HTTP-only cookie.
- [ ] Add short-lived, single-use magic-link records.
- [ ] Store a digest of each magic-link token rather than the raw credential when practical.
- [ ] Add a mailer that sends sign-in links and a development-safe way to inspect delivered links.
- [ ] Redeem a valid magic link into a new session and reject expired, invalid, or previously used links.
- [ ] Associate hosted games with the authenticated host identity.
- [ ] Provide a way for an anonymous host to claim existing games when signing in for the first time.
- [ ] Preserve current game access during the anonymous-to-authenticated migration.
- [ ] Scope all host-owned records through the current authenticated identity.
- [ ] Allow hosts to list and manage their games across browsers and devices.
- [ ] Allow individual sessions to be listed and revoked.
- [ ] Add model tests for token generation, expiration, and one-time redemption.
- [ ] Add integration tests for requesting a link, redeeming it, signing out, and refusing unauthorized access.

Completion criteria:

- A returning host can request a link, sign in without a password, and see all games they own.
- A redeemed or expired link cannot be reused.
- Anonymous games can be claimed without losing players, questions, responses, or results.
- A host cannot access another host's games by changing a URL.
