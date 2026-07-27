# AGENTS.md

The Readium Swift toolkit is used to develop reading apps for iOS, with support for EPUB, PDF, audiobooks and comics.

## Testing

- `scripts/test.sh` runs all tests
- `scripts/test.sh ReadiumSharedTests` runs only the tests for the ReadiumShared package

## Fork 分支维护

- 所有 Hometail fork 修改必须进入唯一长期维护分支 `hometail/readium-3.11`；`hometail/readium-3.10` 仅保留为升级前基线，不再接收修改。
- 不创建、使用或推送 `codex/*` 分支；推送时只推送 `hometail/readium-3.11`。
