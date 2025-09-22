# Red Hat Satellite 6.17 Automated Installation

## Overview

This Ansible project automates the complete installation of Red Hat Satellite 6.17 infrastructure, transforming bare RHEL 9 servers into a fully operational Satellite server with certificate-ready Capsule servers. The automation handles everything from initial host preparation through certificate distribution, ensuring a consistent, production-ready deployment. Consideration for normal and load balanced capsule configuration is considered and is set via the group vars.

## Architecture

The infrastructure follows a hub-and-spoke model:
- **One Satellite Server**: Central management hub that stores all content
- **Multiple Capsule Servers**: Remote content delivery points that sync from Satellite
- **Custom SSL Certificates**: Required for secure communication and load balancer compatibility

## Prerequisites

### Infrastructure Requirements
- **Servers**: RHEL 9.x servers (freshly provisioned)
- **Memory**: Minimum 20GB RAM per server
- **Storage for EO_ITRA deployments**: 
  - One additional disk (beyond OS disk) with 10TB+ capacity for Satellite
  - One additional disk with 6TB+ capacity for each Capsule
  - The automation will automatically detect and configure these disks
- **Network**: 
  - Access to Red Hat CDN (can be through proxy)
  - DNS entries for all servers
  - Network connectivity between Satellite and all Capsules

### Ansible Automation Platform (AAP) Setup
- AAP 2.x with Git project integration
- Configured credentials (see Configuration Guide below)
- Required Ansible collections (defined in `collections/requirements.yml`)

### Certificate Requirements
SSL certificates must be staged in the following structure(folder name is shortname, cert is FQDN)Example:
```
files/
├── prukop/                      # Satellite server directory
│   └── prukop.us.lmco.com.zip  # Certificate bundle for Satellite
└── ebbesen/                     # Capsule server directory
    └── ebbesen.us.lmco.com.zip # Certificate bundle for Capsule
```

Each ZIP file must contain:
- `<fqdn>.crt` - Server certificate
- `<fqdn>.key` - Private key
- `<fqdn>-chain.pem` - Complete certificate chain

### Subscription Allocation setup for your new Satellite
- You have to setup a unique subscription allocation, with the products required for your installs, on the Red Hat Access portal.
- Once setup, you have to collect the UUID that was generated. This put this uuid in the group vars. You MUST change it for every different
  Satellite that you setup (This could be a survey var) The UUID is what allows you to download the manifest zip from Red Hat and import it
  to the freshly installed Satellite server.

## Automation Workflow

### Phase 1: Host Preparation (`prep_satellite_host` role)
**Purpose**: Prepares all servers (both Satellite and Capsules) for installation.

**Key actions**:
1. **Role determination**: Identifies whether each server is a Satellite or Capsule
2. **Storage optimization**: 
   - Automatically detects the additional disk(we modified this so that it uses INT)(Now properly sorting by numeric size, not string   comparison!)
   - Pre-creates Volume Group with 128 MiB PE size (see Storage Optimization section)
   - Creates logical volumes with specific mount points
3. **System configuration**: Sets SELinux to permissive, configures firewall, updates packages
4. **User management**: Creates required service accounts and applies the pgsql override required.

### Phase 2: Satellite Installation (`install_satellite` role)
**Purpose**: Installs Satellite on the designated server.

**Key actions**:
1. Extracts and validates custom SSL certificates
2. Makes sure redhat-up.pem is available(if it is not, you will never get content from the CDN)
3. Registers with Red Hat CDN
4. Runs satellite-installer with organization settings
5. Applies custom certificates to the installation
6. Imports subscription manifest

### Phase 3: Certificate Preparation (`prepare_capsule_certs` role)
**Purpose**: Processes certificate files for each Capsule stipulated in the group vars on the Satellite server.

**Key actions**:
1. Extracts certificates from ZIP files
2. Reformats private keys for compatibility
3. Validates certificates with katello-certs-check

### Phase 4: Generate Capsule Tarballs (`generate_capsule_tar` role)
**Purpose**: Creates certificate deployment packages for each Capsule.

**Key actions**:
1. Runs capsule-certs-generate for each Capsule
2. Creates tarballs containing all required certificates
3. Handles load-balanced Capsules with special parameters
4. Generates installation instructions for each Capsule

### Phase 5: Certificate Distribution (`distribute_capsule_tar` role)
**Purpose**: Copies certificate tarballs, and the generated install command, to respective Capsule servers.

**Key actions**:
1. Uses fetch-copy pattern for reliable cross-zone transfers
2. Validates successful transfer
3. Provides installation instructions on each Capsule

## Storage Optimization

### LVM Physical Extent Size Challenge

The Red Hat storage system role doesn't support customizing the Physical Extent (PE) size for LVM Volume Groups. It defaults to 4 MiB PE size, which creates performance issues for large volumes:

**Impact of Default 4 MiB PE:**
- 8TB volume = 2,097,152 physical extents
- High metadata overhead (~64MB)
- Slower LVM operations
- Higher memory usage

**Our Solution - 128 MiB PE:**
- 8TB volume = 65,536 physical extents (97% reduction)
- Low metadata overhead (~2MB)
- Significantly faster LVM operations
- Lower memory usage

### Implementation

We implemented a pre-creation workaround in `optimize_vg_pe_size.yml`:

1. Before the storage role runs, we check if the Volume Group exists
2. If not, we pre-create it with optimal settings: `vgcreate -s 128M vgsat /dev/diskX`
3. The storage role then adds logical volumes to our pre-optimized VG
4. Result: All benefits of the storage role plus optimal performance

This optimization is critical for:
- Satellite's 8TB+ content storage (`/var/lib/pulp`)
- Large backup volumes (512GB)
- Export volumes (500GB)

### Why Not Custom LVM Commands?

We chose to work with the storage role despite its PE size limitation because:
- It provides consistent, tested volume management
- It handles filesystem creation and mounting reliably
- It's idempotent and safe to re-run
- We only need to work around the PE size limitation

## Load Balancer Support

The automation supports environments where some Capsules are behind a load balancer.
**NOTE**: All capsules have to be in the capsule_fqdns variable - If it is a capsule that will be behind a load balancer it must also be in the 
loadbalanced_capsules vaiable. 

### Configuration
In `group_vars/all.yml`:
```yaml
# List which Capsules are behind the load balancer
loadbalanced_capsules:
  - capsule2.us.lmco.com
  - capsule3.us.lmco.com

# The load balancer FQDN
capsule_loadbalancer_fqdn: "eo-capsules.com"
```

### Certificate Requirements for Load Balancing
Load-balanced Capsules need certificates with:
- Primary: The Capsule's FQDN
- SAN: The load balancer's FQDN

### Automatic Handling
The automation automatically:
- Adds `--foreman-proxy-cname` parameter for load-balanced Capsules
- Generates different installation instructions
- Provides clear guidance in the output files

## Configuration Guide

### Setting Up Your Environment

Edit `group_vars/all.yml` with your environment details:

```yaml
# Critical settings that MUST be updated:
satellite_fqdn: "your-satellite.domain.com"
capsule_fqdns:
  - "capsule1.domain.com"
  - "capsule2.domain.com"

satellite_org: "YourOrganization"
satellite_location: "YourLocation"

server_proxy_hostname: "proxy.domain.com"
uuid: "your-uuid-here"  # From Red Hat Portal
```

### AAP Credentials Configuration

Configure these credentials in your AAP job template:
1. **Machine Credential**: SSH access to target servers
2. **Custom Credential 1**: 
   - `app_username`: Satellite admin username
   - `app_password`: Satellite admin password
3. **Custom Credential 2**:
   - `app_username2`: Red Hat CDN username
   - `app_password2`: Red Hat CDN password

## Running the Playbook

### In Ansible Automation Platform:

1. **Create a Project**: Link to your Git repository
2. **Create an Inventory**: Add Satellite and Capsule servers
3. **Create a Job Template**:
   - Playbook: `satellite-install.yml`
   - Credentials: Add all required credentials
   - Privilege Escalation: Enabled
4. **Launch the Job**: Monitor progress (45-60 minutes typical)

## Error Recovery

### Storage Rollback

The automation includes automatic rollback for storage configuration failures. If volume creation fails:
1. The Volume Group is deactivated and removed
2. Physical volumes are cleaned up
3. The system returns to pre-storage state
4. You can safely re-run the playbook

### Idempotency

All roles are designed to be idempotent. You can safely re-run the playbook:
- Existing configurations are preserved
- Only missing components are created
- Use `force_regenerate: true` to recreate certificates if needed

## Post-Installation Steps

After successful installation:

1. **Access Satellite**: Browse to `https://your-satellite.domain.com`
2. **Login**: Use the admin credentials configured
3. **For each Capsule**: 
   - Certificates are staged in `/root/capsule_cert/`
   - Follow instructions in `<capsule>-install.txt`
   - Note special parameters for load-balanced Capsules
4. **Configure content**: Set up repositories and content views
5. **Register clients**: Begin registering systems to Satellite

## Performance Considerations

### Storage Performance
With PE size optimization:
- LVM operations on 8TB volumes are ~30x faster
- Metadata overhead reduced by 97%
- Snapshot operations significantly faster
- Volume resizing operations more efficient

### Mount Options
Optimized XFS mount options for different workload types:
- `noatime,nodiratime`: Reduce metadata updates
- `largeio,allocsize=128m`: Optimize for large files (ISOs, RPMs)

## Troubleshooting

### Common Issues

**Storage role fails**
- Check that the data disk is not already in use
- Verify disk device name in debug output
- Ensure no existing VG with the same name

**Certificate validation fails**
- Ensure all three files are in the ZIP (crt, key, chain)
- For load-balanced Capsules, verify SAN includes load balancer FQDN
- Check certificate chain completeness

**CDN registration fails**
- Verify proxy settings if behind firewall
- Confirm CDN credentials in AAP
- Check network connectivity to cdn.redhat.com

**AAP reboot issues**
- The playbook uses async shell commands for reboots
- This avoids common AAP connection tracking problems
- Wait times are configurable via `reboot_timeout`

## Technical Notes

### Design Decisions

**VG Pre-creation**: Works around storage role limitation while maintaining its benefits

**Fetch-Copy Pattern**: More reliable than direct copying across network zones

**Custom Certificates**: Required for corporate security and load balancer compatibility

**Rollback Capability**: Prevents partial configurations from blocking re-runs

### Runtime Expectations

- **Duration**: 45-60 minutes for complete installation
- **Reboots**: Systems may reboot once if kernel updates are applied
- **Storage**: VG pre-creation is idempotent and safe to re-run
- **Credentials**: Change default passwords immediately after installation

## Support

For issues:
1. Check Ansible output for specific error messages
2. Verify PE size: `vgs -o vg_name,vg_extent_size`
3. Review storage: `lvs -a -o +devices`
4. Consult Red Hat Satellite 6.17 documentation

---

## Additional Capsule cert and load balanced information:
# Load Balancer Configuration Examples

## Scenario 1: No Load Balancer (Current Default)

```yaml
# All Capsules connect directly, no load balancer
capsule_fqdns:
  - ebbesen.us.lmco.com

loadbalanced_capsules: []
capsule_loadbalancer_fqdn: ""
```

Result: Standard certificate generation for all Capsules.

## Scenario 2: Single Capsule Behind Load Balancer

```yaml
# One Capsule will be behind a load balancer
capsule_fqdns:
  - ebbesen.us.lmco.com
  - capsule2.us.lmco.com

loadbalanced_capsules:
  - capsule2.us.lmco.com

capsule_loadbalancer_fqdn: "eo-capsules.com"
```

Result:
- `ebbesen.us.lmco.com`: Standard certificate generation
- `capsule2.us.lmco.com`: Certificate with `--foreman-proxy-cname eo-capsules.com`

## Scenario 3: Multiple Capsules Behind Same Load Balancer

```yaml
# Multiple Capsules behind the same load balancer
capsule_fqdns:
  - ebbesen.us.lmco.com
  - capsule2.us.lmco.com
  - capsule3.us.lmco.com
  - capsule4.us.lmco.com

loadbalanced_capsules:
  - capsule2.us.lmco.com
  - capsule3.us.lmco.com

capsule_loadbalancer_fqdn: "eo-capsules.com"
```

Result:
- `ebbesen.us.lmco.com`: Standard certificate (not load-balanced)
- `capsule2.us.lmco.com`: Certificate with cname for load balancer
- `capsule3.us.lmco.com`: Certificate with cname for load balancer
- `capsule4.us.lmco.com`: Standard certificate (not load-balanced)

## Scenario 4: All Capsules Behind Load Balancer

```yaml
# All Capsules will be accessed through load balancer
capsule_fqdns:
  - capsule1.us.lmco.com
  - capsule2.us.lmco.com
  - capsule3.us.lmco.com

loadbalanced_capsules:
  - capsule1.us.lmco.com
  - capsule2.us.lmco.com
  - capsule3.us.lmco.com

capsule_loadbalancer_fqdn: "eo-capsules.com"
```

Result: All Capsules get certificates with `--foreman-proxy-cname eo-capsules.com`

## What Happens During Certificate Generation

### For Standard Capsules:
```bash
capsule-certs-generate \
  --foreman-proxy-fqdn ebbesen.us.lmco.com \
  --certs-tar /root/capsule_cert/ebbesen/ebbesen.us.lmco.com-certs.tar \
  --server-cert /root/capsule_cert/ebbesen/ebbesen.us.lmco.com.crt \
  --server-key /root/capsule_cert/ebbesen/ebbesen.us.lmco.com.key \
  --server-ca-cert /root/capsule_cert/ebbesen/ebbesen.us.lmco.com-chain.pem
```

### For Load-Balanced Capsules:
```bash
capsule-certs-generate \
  --foreman-proxy-fqdn capsule2.us.lmco.com \
  --certs-tar /root/capsule_cert/capsule2/capsule2.us.lmco.com-certs.tar \
  --server-cert /root/capsule_cert/capsule2/capsule2.us.lmco.com.crt \
  --server-key /root/capsule_cert/capsule2/capsule2.us.lmco.com.key \
  --server-ca-cert /root/capsule_cert/capsule2/capsule2.us.lmco.com-chain.pem \
  --foreman-proxy-cname eo-capsules.com  # ADDED FOR LOAD BALANCER
```

## Install Instructions File Differences

### Standard Capsule (ebbesen.us.lmco.com-install.txt):
```
[Output from capsule-certs-generate]

================================================================
STANDARD CAPSULE CONFIGURATION
================================================================
This is a standard (non-load-balanced) Capsule configuration.
Run the satellite-installer command exactly as shown above.
================================================================
```

### Load-Balanced Capsule (capsule2.us.lmco.com-install.txt):
```
[Output from capsule-certs-generate]

================================================================
LOAD BALANCER CONFIGURATION REQUIRED
================================================================
This Capsule is configured for load balancing.
Load Balancer FQDN: eo-capsules.com

IMPORTANT: When running the satellite-installer command on the Capsule,
you MUST append these additional options:

--certs-cname "eo-capsules.com" \
--enable-foreman-proxy-plugin-remote-execution-script

These options are REQUIRED for load-balanced Capsules to function correctly.
================================================================
```

## Certificate Requirements

For load-balanced Capsules, the custom SSL certificate MUST include:

1. **Primary**: The Capsule's FQDN (e.g., `capsule2.us.lmco.com`)
2. **SAN**: The load balancer's FQDN (e.g., `eo-capsules.com`)

Example certificate SAN entries:
```
DNS:capsule2.us.lmco.com
DNS:eo-capsules.com
```

Without both entries, clients connecting through the load balancer will get certificate validation errors!