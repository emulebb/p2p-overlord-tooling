# PowerShell Mistakes

- `npx prisma migrate reset --force --skip-seed`
  - Prisma 7.5.0 in this workspace does not support `--skip-seed` for `migrate reset`.
  - Use `npx prisma migrate reset --force` instead.
