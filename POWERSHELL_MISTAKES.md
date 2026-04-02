# PowerShell Mistakes

- `npx prisma migrate reset --force --skip-seed`
  - Prisma 7.5.0 in this workspace does not support `--skip-seed` for `migrate reset`.
  - Use `npx prisma migrate reset --force` instead.
- `rg -n "..." C:\path\to\*.cpp`
  - `rg` on Windows does not accept raw wildcard-expanded absolute path arguments that way and returns `os error 123`.
  - Search a directory root instead, for example `rg -n "pattern" C:\path\to\dir`.
- `Format-Hex -Path <file> -Count 128`
  - PowerShell 7 `Format-Hex` does not support `-Count`, and it also fails if the file is still open by another process.
  - Stop the writer first, then use `Get-Content -Encoding utf8` for JSONL inspection or `Format-Hex -Path <file>` without `-Count`.
