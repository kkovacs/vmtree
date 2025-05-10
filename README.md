# 🌳VMTREE is easy ephemeral VMs on your own server.

These scripts turn a server (or VM) into a "VM tree", on which you can easily start up ephemeral VMs. Originally for our **self-hosted** [cloud development environments](https://www.usenimbus.com/post/the-guide-to-cloud-dev-environments), but usable in many ways: in a **CI/CD pipeline**, as **acceptance testing environments**, for **demoing purposes**, or really anything you can use an Ubuntu VM for.

With 🌳VMTREE, you provision a new VM just by SSH-ing into it: `ssh demo-foo.example.com` starts up a fresh VM called `demo-foo` and connects to it. Running `sudo touch /killme` destroys it.

We didn't develop this as a product, but to scratch our own itch as a DevOps team. We've been using this (and its previous in-house version) for 5+ years as our dev environments, and we ❤️ that fresh VMs just _"grow on the VM tree for easy picking"_. It's literally how our team survived COVID's years of WFH. :)

It's the same philosophy as [GitPod](https://www.gitpod.io/), [DevPod](https://devpod.sh/), [CodeSpaces](https://github.com/features/codespaces), [CodeSandbox](https://codesandbox.io/) or [Nimbus](https://www.usenimbus.com/), but **self-hosted**, free (as in beer and speech) and probably a bit more old-school:
- uses just `ssh`,
- all written in `bash`,
- the VMs are regular Ubuntu VMs with a near-zero learning curve,
- no `docker` or `k8s` involved, no `.json` files in `git` repos (but you can add anything if you want to),
- you are not forced to use VSCode (although you can). (Hello `vim`! 😁)

For the VMs, it uses [LXD containers](https://canonical.com/lxd) or [QEMU VMs](https://ubuntu.com/blog/lxd-virtual-machines-an-overview).

## Features

- You and your team can start up new VMs just by SSH-ing into them.
- Works seamlessly with Visual Studio Code's official [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.
- Uses LXD containers, which share RAM, CPU and disk space, providing high VM density.
- There are "personal" and "shared" VMs. (Shared VMs are the ones starting with `demo-`. Personal ones with `username-`.)
- Port 80 of every VM is automatically exposed over HTTPS, like `https://demo-foo.example.com`. (A pre-configured [Caddy reverse-proxy](https://caddyserver.com/) deals with TLS and forwards HTTP requests to the right VM.)
- But every subdomain is protected with HTTP password automatically, so forgetful humans don't accidentally expose random stuff to the world. (Can be disabled on a per-VM basis by `sudo touch /nopassword`.)
- The directory `/persist/` is shared between a user's all personal VMs. (Makes working on multiple VMs easy, even at the same time.)
- VMs are considered ephemeral: by default all VMs "die" at night, to protect resources from forgetful humans. (Can be disabled on a per-VM basis by `sudo touch /nokill`.)
- But files in `/persist/` are persistent and survive the nightly killing of VMs. (So it's recommended to keep your work there.)
- LXD containers are pre-configured to be `docker`-compatible.
- By default VMs are running Ubuntu, but you can request different OSes just by provisioning the VM like this: `ssh demo-foo-centos8.example.com` (Then on you can use just `demo-foo.example.com`.)
- Personal VMs are protected from other users, but can still be shared if a teammate's SSH key is put in `/home/user/.ssh/authorized_keys` by the VM's owner.
- You can use it on an Internet-based server or on-prem behind a corporate firewall: it just needs the wildcard DNS settings and a wildcard TLS certificate. (We do use it both ways.)

## How does it work?

- You install this on an Ubuntu server, and put a small snippet in your `.ssh/config`. (And your team members'.)
- When you SSH to a 🌳VMTREE VM, your SSH client resolves the VM name you requested to the same server, because of the wildcard DNS domain.
- Your `.ssh/config` snippet specifies to use a "jump" user called `vmtree` on the server. (Only the people who have their SSH key in the `vmtree` user's `authorized_keys` file can connect, of course.)
- The `vmtree` user's `authorized_keys` file force-runs the `/vmtree/vmtree-vm.sh` script on the server. (It's not possible to run anything else via SSH with this user.)
- The SSH snippet in your `.ssh/config` passes name of the VM you requested to the `/vmtree/vmtree-vm.sh` script.
- The `/vmtree/vmtree-vm.sh` script does security checks regarding naming convention, etc.
- The `/vmtree/vmtree-vm.sh` script starts an LXD container with the VM name you specified, passing it a [cloud-init](https://cloud-init.io/) script that pre-configures the VM with your SSH key (and possibly other things).
- The `/vmtree/vmtree-vm.sh` script attaches your "personal disk" to the VM at `/persist/`.
- The `/vmtree/vmtree-vm.sh` script waits for the VM to obtain an IP address and have SSH started.
- The `/vmtree/vmtree-vm.sh` script connects your SSH session to the SSH port of the LXD container.
- You are in! You can use the LXD container just as you would with any other VM.

And from `cron`:

- Every minute, `/vmtree/cron-killme.sh` checks for a `/killme` file on the VMs, and if one's there, deletes the VM.
- Every minute, `/vmtree/cron-nopassword.sh` checks for a `/nopassword` file on the VMs, and if one's there, reconfigures Caddy to NOT do HTTP authentication for the VM's subdomain.
- Every day (by default at 6am), `/vmtree/cron-stop.sh` checks for a `/nokill` file on the VMs, and if the file is NOT THERE, deletes the VM. (If it's a personal VM, still stops the VM, but doesn't delete. This is because people forget about their VMs.)
- Every day `/vmtree/cron-renew.sh` checks if the TLS certificate needs to be renewed, and renews it if necessary, with [acme.sh](https://github.com/acmesh-official/acme.sh).

## Any disadvantages?

Just a few.

- You will be asked twice for SSH authorization. (Once for the jump user, and once for the freshly created VM.)
- LXD containers are _nearly_ full VMs, but have some security limits regarding mounting file systems, setting system parameters, etc. These rarely interfere with normal dev tasks, and when you need, you CAN start up real VMs, too (see below).
- The Caddy http auth protects the VMs from the world outside the server, but not from other VMs on the same server. (Then again, it's assumed that your server is being used by your own team, not by your enemies.)
- As of now there is no support company, foundation, charity, etc behind this open-source project. On the other hand, it's barely 600 lines of `bash` code (including comments), so I'm pretty sure your DevOps team can deal with it if necessary.

## You can use both LXD containers *and* QEMU VMS

When you occasionally run into LXD's limitations, , you can start _real_ QEMU VMs instead of LXD containers by specifying `-vm` as the 4th part of the VM name. For example `ssh demo-myrealvm1-ubuntu2004-vm8.example.com` creates a QEMU VM called "demo-myrealvm1", using 8GB of memory, running an older Ubuntu version, 20.04.

Full QEMU VMs are needed -- for example -- if you want to run a full Kubernetes cluster on the VM. (But `docker` and `docker-compose` does work on LXD containers with the configuration that these scripts already do for you.)

The advantages of QEMU VMs is that they have fewer limitations, but the disadvantage is that they allocate the memory they are given (memory is not shared, as it is with LXD containers).

## Basic installation (using a self-signed certificate)

On an Ubuntu 24.04 or 22.04 server with a public IP address, run:

```bash
sudo git clone https://github.com/kkovacs/vmtree.git /vmtree
sudo cp ~/.ssh/authorized_keys /vmtree/keys/my
sudo /vmtree/install.sh
```

Then put the snippet it prints out in your `.ssh/config` file (on your PC, not on the server, of course).

This basic setup will use [ip.me](https://ip.me/), [nip.io](https://nip.io/), and a self-signed certificate to set up the fullest possible functionality without using your own domain.

## Full installation (using your own real wildcard certificate)

1. Get a domain that you will use for VMTREE. (From now on: `example.com`).
1. Host the domain on a DNS provider [supported by acme.sh](https://github.com/acmesh-official/acme.sh/wiki/dnsapi). (Needed for the wildcard TLS certificate.)
1. Get a powerful host server that you will use for VMTREE, running Ubuntu 22.04 or 24.04.
1. Configure DNS so `example.com` and `*.example.com` point to the host server's IP. (Wait until it propagates.)
1. On your host server, `sudo git clone https://github.com/kkovacs/vmtree.git /vmtree`
1. Copy your and your teams's SSH public keys (`~/.ssh/id_*.pub` files on their PCs) to `/vmtree/keys/<username>` files.
1. Run `sudo /vmtree/install.sh --skip-install` to do basic checks and generate a default `/vmtree/.env` file.
1. It will say that you need to fill out the `/vmtree/.env` file. Fill out:
   - your domain name (`example.com`)
   - your desired automatic HTTP AUTH username / password
   - your DNS provider and its token to use with acme.sh
   - optionally, a storage disk/partition (will be formatted with ZFS)
1. Run `sudo /vmtree/install.sh` again to finish the installation.
1. Distribute the snippet it prints out to your team, to put into their `.ssh/config` files.
