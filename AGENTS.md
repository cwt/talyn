# Developer Agent Instructions

This repository uses the Open Knowledge Format (OKF v0.2) to document development rules, architectural mandates, and lessons learned.

## OKF Bundle Root
- **Master Documentation Bundle**: Located at [docs/](docs/)
  - **Master Root Index File**: [docs/index.md](docs/index.md) (contains master priorities, knowledge base, benchmarks, and history)
- **Development Documentation Bundle**: Located at [docs/development/](docs/development/)
  - **Development Index File**: [docs/development/index.md](docs/development/index.md) (contains priorities, bugs, and development history)
  - **Lessons Learned Index**: [docs/development/lessons/index.md](docs/development/lessons/index.md) (nested topic bundle index)

## Rules for Agents
Before implementing any changes, refactoring, or writing new code:
1. **Load and read** the root index [docs/index.md](docs/index.md).
2. **Review and adhere** to the [docs/development/architectural-mandates.md](docs/development/architectural-mandates.md) (e.g. panic prevention rules, event loop shutdown guard rules, thread safety requirements).
3. **Inspect** the specific lesson categories under [docs/development/lessons/](docs/development/lessons/) relevant to your active task to ensure past bugs are not reintroduced.
