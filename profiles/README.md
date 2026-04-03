# Profiles

Generated runtime profiles, profile templates, and profile materialization logic
belong here.

Deterministic oracle and agent runs should treat profiles as first-class
reproducibility inputs rather than ad-hoc copied config files.

Oracle harness policy:

- seeded `preferences.ini` files must contain only the minimal settings needed
  for the harness and scenario contract
- avoid carrying unrelated UI, history, or workstation-specific noise into
  deterministic seeded profiles
