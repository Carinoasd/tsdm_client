# Implementation plan — approved silent blocking

Baseline: 7a3b0f59. Branch feat/silent-blocking. User approved revised design with "go".
1. Claude implements account-scoped durable local UID block storage and change notification, with an explicit no-server-blacklist contract.
2. Claude wires profile/management UI and shared content filtering: topic lists/search, reply placeholders/direct thread protection, reliable notice-source filtering including notification delivery/counts. Keep PM and friendship unchanged.
3. Claude implements independent forum notification ignore form parsing, submit and safe removal; persist reliable notice metadata with backwards-compatible schema migration if needed.
4. Claude adds i18n and focused behavior tests, documents generated-code steps and limitations. Codex owns environment/generation/test execution if Claude shell permissions prevent it.
5. Codex reviews all changes, regenerates code, executes focused then full appropriate tests and analyzer/build checks. Failures and design findings are sent to Claude for discussion/fixes.
6. Revalidate changed areas, package reviewable diff and acceptance report. No merge, push, release, real-account operations or credential access.
