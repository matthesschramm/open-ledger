# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Open Ledger, please report it responsibly:

**DO NOT** open a public GitHub issue for security vulnerabilities.

Instead, please use GitHub's private vulnerability reporting feature:

1. Go to the [Security tab](https://github.com/matthesschramm/open-ledger/security) of the repository
2. Click "Report a vulnerability"
3. Provide detailed information about the vulnerability

Alternatively, you can email security details to the maintainers through GitHub.

## What to Include

When reporting a security issue, please include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (if you have them)

## Response Timeline

- We will acknowledge receipt of your vulnerability report within 48 hours
- We will provide a more detailed response within 7 days
- We will work on a fix and notify you when it's ready for testing
- Once the fix is verified, we will release a patch and credit you (unless you prefer to remain anonymous)

## Supported Versions

We provide security updates for:
- The latest release on the `main` branch
- The most recent tagged release

## Security Best Practices

When deploying Open Ledger:

1. **Never commit secrets**: Use environment variables for all sensitive configuration
2. **Rotate API keys regularly**: Especially for production environments
3. **Use HTTPS**: Always deploy with SSL/TLS enabled
4. **Restrict database access**: Follow principle of least privilege
5. **Keep dependencies updated**: Run `bun update` regularly to get security patches
6. **Enable audit logging**: Use Supabase audit logs in production
7. **Review RLS policies**: Ensure Row Level Security policies are properly configured

## Known Security Considerations

- Service role keys have full database access - protect them carefully
- API keys grant organization-scoped access - rotate them if compromised
- Email sending uses Resend API keys - keep these secure

Thank you for helping keep Open Ledger secure!
