# Incident and Rollback Runbook

1. Disable the affected external provider/model in the signed eligibility or model manifest; local mode remains the safe baseline.
2. Publish an expiring parent-visible advisory without child data or secrets.
3. Preserve only redacted operational evidence. Never export conversation, voice, database keys, or API keys.
4. Roll back to the last verified model/app release through the atomic previous-version slot.
5. If confidentiality may be affected, revoke provider credentials, destroy wrapped content keys where scoped, and guide the parent through delete-all.
6. Re-enable only after root cause, regression tests, privacy capture, safety review, and signed release approval.

Immediate shutdown triggers include key exposure, unexpected local-mode traffic, remotely exploitable loopback access, model signature bypass, unencrypted user data, or a reproducible high-severity child-safety bypass.
