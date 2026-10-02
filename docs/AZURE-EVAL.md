# Azure evaluation host

A small Docker host on the Azure free trial, created on 2026-10-02 to compare Azure with the production AWS server. Production stays on AWS. This VM has 1 GiB of memory, so it can run a small container while the comparison is open.

Playbook for agents: `.cursor/rules/azure-eval.mdc`.

## What is running

| | |
|---|---|
| Subscription | `Azure subscription 1` (`78feae20-0a5d-4cb2-b999-8b631be7df39`) |
| Offer | `FreeTrial_2014-09-01`, spending limit **On** |
| Sign-in | `admin@prabhixtechnologies.com`, tenant `0e197257-d278-473d-9017-4f00804b2645` |
| Region | `centralindia` |
| Resource group | `prabhix-docker-rg` |
| VM | `prabhix-docker` |
| Size | `Standard_B2ats_v2` — 2 burstable AMD vCPUs, 1 GiB RAM, 20% baseline |
| Image | Ubuntu 24.04 LTS (`Canonical:ubuntu-24_04-lts:server:24.04.202609040`) |
| OS disk | 64 GB Premium SSD (`Premium_LRS`), the free P6 allowance |
| Public IP | `20.235.99.156` (`prabhix-dockerPublicIP`, Standard) |
| Private IP | `10.0.0.4` |
| SSH user | `prabhix` |
| Key | `%USERPROFILE%\.ssh\prabhix-azure-docker` |
| SSH source | `150.129.236.69/32` only, NSG `prabhix-docker-nsg`, rule `AllowSshFromHome` |
| Software | Docker 29.1.3, Docker Compose 2.40.3 |

`Standard_B2ats_v2` is the strongest x64 size in the 12-month free VM allowance (750 hours of B1s, B2ats v2, and B2pts v2). B2pts v2 is the same shape on Arm, which breaks ordinary amd64 images. Do not pin availability zones 2 or 3 in Central India: this subscription cannot place `Standard_B2ats_v2` there. Leave the zone unset.

The Azure portal still lists the original provisioned admin as `azureuser`. SSH does not. `AllowUsers prabhix` is in `/etc/ssh/sshd_config.d/00-allow-prabhix.conf`, the `azureuser` shell is `/usr/sbin/nologin`, its password is locked, and its `authorized_keys` file is gone.

## Sign in

Azure CLI on this PC is 2.90.0, installed with `winget install --exact --id Microsoft.AzureCLI`. If `az account show` fails:

```powershell
az login --use-device-code
```

```powershell
ssh -i $env:USERPROFILE\.ssh\prabhix-azure-docker prabhix@20.235.99.156
```

`prabhix` is in the `sudo` and `docker` groups and has passwordless sudo.

## Free allowance and the parts that cost money

The VM size and the 64 GB Premium disk sit inside the 12-month amounts: 750 hours a month, and two P6 disks. One always-on B2ats v2 uses about 730 hours, so a second VM in the same month is billed.

The Standard public IP is a paid resource. While the spending limit is on, that charge draws the $200 credit and the card is not billed. Within 30 days of signup, or when the credit is used, switch the subscription to pay-as-you-go or Azure disables the account and the free amounts with it. After 12 months the VM itself bills at normal rates if it is still running.

Outbound data past the included 15 GB also bills. Confirm the live meters at [Azure free services](https://azure.microsoft.com/en-us/pricing/free-services) before treating this as zero cost.

## When this PC's address changes

```powershell
$ip = Invoke-RestMethod https://api.ipify.org
az network nsg rule update --resource-group prabhix-docker-rg --nsg-name prabhix-docker-nsg --name AllowSshFromHome --source-address-prefixes "$ip/32"
```

## Rebuild with prabhix as the provisioned admin

Use this when the VM has to be created again. `--admin-username prabhix` avoids a second rename. Reuse the existing key. A new public IP is assigned unless the current `prabhix-dockerPublicIP` is kept and passed with `--public-ip-address`.

Save this as the cloud-init file:

```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
runcmd:
  - systemctl enable --now docker
  - usermod -aG docker prabhix
```

```powershell
az group create --name prabhix-docker-rg --location centralindia
az network nsg create --resource-group prabhix-docker-rg --name prabhix-docker-nsg --location centralindia
az network nsg rule create --resource-group prabhix-docker-rg --nsg-name prabhix-docker-nsg --name AllowSshFromHome --priority 1000 --access Allow --protocol Tcp --direction Inbound --source-address-prefixes 150.129.236.69/32 --destination-address-prefixes "*" --destination-port-ranges 22 --source-port-ranges "*"
az vm create --resource-group prabhix-docker-rg --name prabhix-docker --location centralindia --image Ubuntu2404 --size Standard_B2ats_v2 --admin-username prabhix --authentication-type ssh --ssh-key-values "$env:USERPROFILE\.ssh\prabhix-azure-docker.pub" --nsg prabhix-docker-nsg --public-ip-sku Standard --os-disk-size-gb 64 --storage-sku Premium_LRS --custom-data cloud-init.yaml
```

After the first boot, add the same sudo drop-in the current host has:

```bash
printf '%s\n' 'prabhix ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/prabhix
sudo chmod 440 /etc/sudoers.d/prabhix
```

## Stop or remove it

Deallocating the VM stops the compute hours. The Standard public IP keeps its charge until the IP or the resource group is deleted.

```powershell
az vm deallocate --resource-group prabhix-docker-rg --name prabhix-docker
az group delete --name prabhix-docker-rg --yes
```

Delete the group only when this comparison is finished.

## Side by side with production AWS

| | Azure evaluation | Production AWS |
|---|---|---|
| Role | Comparison Docker host | Live stack |
| Size | `Standard_B2ats_v2`, 2 burstable vCPUs, 1 GiB | `c7i-flex.large`, 2 vCPUs, 4 GiB |
| Address | `20.235.99.156` | Elastic IP `35.154.59.116`, instance `i-05496f940af0517ae` |
| Login | `prabhix` with `prabhix-azure-docker` | `prabhix` with `%USERPROFILE%\.ssh\PrabhixTechnologies.pem` |
| Region | `centralindia` | `ap-south-1b` |
| Cost shape | VM hours and a 64 GB disk inside the 12-month allowance; public IP uses the trial credit | On-demand EC2, documented in `Infra/docs/AWS-ACCESS.md` |
