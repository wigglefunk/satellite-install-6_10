# Red Hat Satellite 6.17 Automated Installation

## Overview

This Ansible project automates the complete installation of Red Hat Satellite 6.17 infrastructure, transforming bare RHEL 9 servers into a fully operational Satellite server with certificate-ready Capsule servers. The automation handles everything from initial host preparation through certificate distribution, ensuring a consistent, production-ready deployment every time.

## Why This Project Exists

Our infrastructure team provisions standard RHEL 9 servers that don't meet Satellite's specific requirements. This automation bridges that gap by:
- Configuring the exact storage layout Satellite demands (9.7TB across 14 mount points)
- Installing and configuring all prerequisites
- Implementing custom SSL certificates (corporate security requirement)
- Generating and distributing Capsule certificates for distributed architecture

## Prerequisites

### Infrastructure Requirements
- **Servers**: RHEL 9.x servers (freshly provisioned)
- **Memory**: Minimum 20GB RAM per server
- **Storage**: 
  - One additional disk (beyond OS disk) with 10TB+ capacity
  - Disk will be automatically detected and configured
- **Network**: 
  - Access to Red Hat CDN (direct or through proxy)
  - DNS resolution for all server FQDNs
  - Communication between Satellite and all Capsules

### Ansible Automation Platform (AAP) Requirements
- AAP 2.x with Git project support
- Credentials configured for:
  - Target servers (SSH)
  - Red Hat CDN (username/password or activation key)
  - GitLab repository access

### Certificate Requirements
Custom SSL certificates must be placed in the repository file structure before deployment. See [Certificate Preparation](#certificate-preparation) section.

## AAP Integration

### Project Configuration

1. **Create Project in AAP**
   - Name: `Satellite-6.17-Installation`
   - Source Control Type: Git
   - Source Control URL: `https://gitlab.yourcompany.com/path/to/repo`
   - Source Control Credential: (Your GitLab credential)

2. **Enable Pre-Sync Script**
   
   In project settings, add this pre-sync script to handle external role dependencies:
   ```bash
   #!/bin/bash
   if [ -f roles/requirements.yml ]; then
     echo "Installing roles from roles/requirements.yml..."
     ansible-galaxy install -r roles/requirements.yml --force -p ./roles/
     echo "Roles installed successfully"
   else
     echo "No roles/requirements.yml found. Skipping role install."
   fi
   ```
   This automatically installs the required `fcmcontrol-user-creation` and `postgres-user-override` roles from internal GitLab.

3. **Create Job Template**
   - Name: `Install-Satellite-6.17`
   - Inventory: (Select inventory with Satellite server)
   - Project: `Satellite-6.17-Installation`
   - Playbook: `satellite-install.yml`
   - Credentials: 
     - Machine credential for target servers
     - Custom credential for CDN access (if not using variables)

### Required AAP Credentials

Create these custom credentials in AAP:

1. **Red Hat CDN Credential**
   - `redhat_cdn_username`: Your Red Hat account
   - `redhat_cdn_password`: Your Red Hat password
   - These will be injected at runtime

2. **Satellite API Credential** (Post-installation)
   - `satellite_api_username`: Will be created during install
   - `satellite_api_password`: API token generated after install

## Certificate Preparation

### Critical Importance
Satellite and all Capsules REQUIRE valid SSL certificates for production use. Self-signed certificates are not acceptable in our environment due to security policies and load balancer requirements.

### Certificate File Structure
```
files/
├── <satellite_shortname>/
│   └── <satellite_fqdn>.zip
└── <capsule_shortname>/
    └── <capsule_fqdn>.zip
```

### Example Structure
```
files/
├── prodsat/
│   └── prodsat.example.com.zip
├── prodcapsule1/
│   └── prodcapsule1.example.com.zip
└── prodcapsule2/
    └── prodcapsule2.example.com.zip
```

### ZIP File Contents
Each ZIP file must contain:
- `<fqdn>.crt` - Server certificate
- `<fqdn>.key` - Private key (will be reformatted automatically)
- `<fqdn>-chain.pem` - Complete certificate chain including intermediate and root CAs

### Certificate Deployment Process
1. Before running the playbook, replace the placeholder `fake.zip` files with real certificate ZIPs
2. Ensure ZIP filenames exactly match the server FQDNs
3. The automation will:
   - Extract certificates
   - Reformat private keys for Satellite compatibility
   - Validate with `katello-certs-check`
   - Apply to Satellite/generate for Capsules

## Configuration Variables

Edit `group_vars/all.yml` before deployment. Here's what must be updated and why:

### Essential Variables to Update

```yaml
# The FQDN of your Satellite server - must match DNS and certificate
satellite_fqdn: "satellite.yourdomain.com"

# Short hostname - used for file paths (no dots allowed in folder names)
satellite_shortname: "satellite"

# List of ALL Capsule FQDNs that will connect to this Satellite
# This is the "master list" that determines which hosts get Capsule certificates
capsule_fqdns:
  - "capsule1.yourdomain.com"
  - "capsule2.yourdomain.com"
  # Add all your Capsules here

# Your organization name in Satellite
satellite_org: "YourOrganization"

# Initial admin password for Satellite UI
# Change immediately after installation
satellite_initial_admin_password: "ChangeMe123!"

# Proxy configuration if required for CDN access
server_proxy_hostname: "proxy.yourdomain.com"

# CDN registration UUID (from Red Hat portal)
redhat_cdn_uuid: "your-uuid-here"
```

### Variables Injected by AAP

These are referenced but not defined in `group_vars/all.yml` - AAP provides them:

```yaml
# Provided by AAP credentials at runtime
redhat_cdn_username: "{{ vault_cdn_username }}"
redhat_cdn_password: "{{ vault_cdn_password }}"

# Created AFTER Satellite installation - for future automation
satellite_api_username: "{{ api_username }}"
satellite_api_password: "{{ api_token }}"
```

### Storage Variables

Generally don't need modification unless you have different size requirements:
- `satellite_storage_config` - Defines 14 volumes totaling ~9.7TB
- `capsule_storage_config` - Similar layout for Capsules
- Both optimized with 128MB PE size for large volumes

## How It Works

### Phase 1: Host Preparation
The provisioned servers aren't ready for Satellite. This phase:
- Creates optimized LVM layout (14 specific mount points)
- Installs required packages
- Configures system settings (SELinux, firewall)
- Creates required user accounts
- Cleans any existing Satellite registrations

### Phase 2: Satellite Installation
Installs Satellite on the designated server:
- Extracts and validates custom SSL certificates
- Registers with Red Hat CDN
- Enables Satellite 6.17 repositories
- Runs satellite-installer with organization configuration
- Applies custom certificates to the installation

### Phase 3: Capsule Certificate Preparation
Prepares certificates for all Capsules:
- Extracts custom SSL certificates for each Capsule
- Validates certificates with katello-certs-check
- Stages them for tar generation

### Phase 4: Capsule Certificate Generation
Satellite generates deployment packages:
- Creates certificate tarballs using `capsule-certs-generate`
- Includes both custom certificates and Satellite CA
- Generates installation instructions for each Capsule

### Phase 5: Certificate Distribution
Distributes certificates to Capsules:
- Each Capsule receives its specific certificate tarball
- Uses fetch-copy pattern for reliable transfer
- Validates successful distribution

## Running the Playbook

This playbook is designed to run exclusively through AAP:

1. Ensure all prerequisites are met
2. Update `group_vars/all.yml` with your environment details
3. Place real certificate ZIP files in the `files/` directory structure
4. Commit changes to GitLab
5. In AAP:
   - Sync the project
   - Launch the job template
   - Monitor progress

Expected runtime: 45-60 minutes for complete installation

## Troubleshooting

### Common Issues and Solutions

**Playbook fails at certificate extraction**
- Verify ZIP files exist in correct directory structure
- Ensure ZIP filenames exactly match FQDN
- Check ZIP contains all three required files (.crt, .key, -chain.pem)

**Storage configuration fails**
- Verify additional disk is attached and visible (`lsblk`)
- Ensure disk is not mounted or in use
- Check disk is at least 10TB

**CDN registration fails**
- Verify proxy settings if behind corporate firewall
- Confirm CDN credentials are valid
- Make sure the UUID is correct.
- Check network connectivity to cdn.redhat.com

**Certificate validation fails**
- Ensure certificate chain is complete (includes all intermediates)
- Verify certificate matches the private key
- Check certificate is valid for the server FQDN

**Capsule can't find its certificate tarball**
- Verify Capsule FQDN is in the `capsule_fqdns` list
- Ensure certificate was generated (check `/root/capsule_cert/` on Satellite)
- Confirm fetch-copy completed successfully

### Validation Commands

After successful installation, verify on the Satellite server:

```bash
# List generated Capsule certificates
ls -la /root/capsule_cert/*/
```

## Architecture Notes

This automation implements a hub-and-spoke architecture:
- **One Satellite Server**: Central management, content source
- **Multiple Capsules**: Distributed content delivery, load balancing
- **Custom Certificates**: Required for security compliance and load balancer compatibility

The Satellite server must be installed first and is the source of trust for all Capsules. Each Capsule receives a unique certificate package that enables secure communication with the Satellite server.
This project does not currently consider the manifest import.

## Security Considerations

- Certificates are distributed over SSH using Ansible's secure transport
- Private keys are automatically reformatted for compatibility
- All certificates procured and validated before use
- File permissions are set to 0600 for sensitive files

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review Ansible playbook output for specific errors
3. Verify all prerequisites are met


---