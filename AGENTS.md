# Developer Agent Instructions

This repository uses the Open Knowledge Format (OKF v0.1) to document development rules, architectural mandates, and lessons learned.

## OKF Bundle Root
- **Talyn Documentation Bundle**: Located at [docs/](docs/)
  - **Root Index File**: [docs/index.md](docs/index.md) (contains priorities and knowledge base links)
  - **Lessons Learned Index**: [docs/lessons/index.md](docs/lessons/index.md) (nested bundle index)

## Rules for Agents
Before implementing any changes, refactoring, or writing new code:
1. **Load and read** the root index [docs/index.md](docs/index.md).
2. **Review and adhere** to the [docs/architectural-mandates.md](docs/architectural-mandates.md) (e.g. panic prevention rules, event loop shutdown guard rules, thread safety requirements).
3. **Inspect** the specific lesson categories under [docs/lessons/](docs/lessons/) relevant to your active task to ensure past bugs are not reintroduced.
