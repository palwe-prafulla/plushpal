# PlushPal model release metadata

The manifests in this directory pin approved public model artifacts by exact byte size, SHA-256, runtime compatibility, source, and license. Runtime installation accepts a manifest only after Ed25519 verification against the private-beta public key.

The signing private key is never stored in this repository. The checked-in trust root and signature authorize only the exact manifest bytes committed here. A production release must rotate to an offline production signing key after model-quality, child-safety, performance, redistribution, and legal review.
