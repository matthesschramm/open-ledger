# Contributing to Open Ledger

Thank you for your interest in contributing to Open Ledger! We welcome contributions from the community.

## How to Contribute

### Reporting Issues

If you find a bug or have a feature request:

1. Check if the issue already exists in the [GitHub Issues](https://github.com/matthesschramm/open-ledger/issues)
2. If not, create a new issue with:
   - A clear, descriptive title
   - Steps to reproduce (for bugs)
   - Expected vs. actual behavior
   - Your environment (OS, Bun version, etc.)

### Submitting Changes

1. **Fork the repository** and create a new branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**:
   - Follow the existing code style
   - Write clear, concise commit messages
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**:
   ```bash
   bun test
   bun run typecheck
   ```

4. **Submit a pull request**:
   - Provide a clear description of the changes
   - Reference any related issues
   - Ensure all tests pass

## Development Setup

See the [README.md](./README.md) for detailed setup instructions.

## Code Style

- We use TypeScript for type safety
- Follow the existing code formatting
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions focused and testable

## Testing

- Write tests for new features and bug fixes
- Ensure existing tests still pass
- Test migrations thoroughly before submitting

## Database Migrations

When making schema changes:

1. Create a new migration file in `supabase/migrations/`
2. Use the naming convention: `YYYYMMDDHHMMSS_description.sql`
3. Test the migration on a local Supabase instance
4. Document any breaking changes

## Questions?

If you have questions about contributing, feel free to:
- Open an issue for discussion
- Reach out through GitHub Discussions

We appreciate your contributions!
