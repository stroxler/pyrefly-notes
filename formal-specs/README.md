# Formal specifications

Executable models and model-checking experiments for Pyrefly development.
Each experiment belongs in its own subdirectory and should state its source
snapshot, assumptions, checked scope, and known limitations.

- [Pyrefly SCC solving](pyrefly-scc/): original TLA+ models, a current-source
  audit, and reproducible coverage/deadlock probes.
- [Lambda inference contexts](lambda-inference/): a native Alloy 6 temporal
  sketch of publication authority and ThreadState hint storage, with checked
  traces.
