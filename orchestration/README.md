# Orchestration

Process control, run locking, environment checks, and reproducible session
orchestration belong here.

Platform wrappers should call into this area instead of embedding repeated
launch/stop/session logic directly in many standalone scripts.
