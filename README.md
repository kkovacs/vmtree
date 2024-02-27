# 🌳VMTREE is an easy way to make ephemeral VMs.

This is a collection of scripts that turn a server into a "VM tree", on which you can start up (and delete) ephemeral [LXD containers](https://linuxcontainers.org/lxd/) -- basically VMs.

The way to procure a new VM is just to SSH into it. `ssh demo-foo.example.com` starts up a fresh VM called `demo-foo` and connects to it. `sudo touch /killme` destroys it.

Our DevOps team has been using this for years for our self-hosted cloud development environments, and we ❤️ that fresh VMs just grow on the "VM tree" for easy picking.

It's the same philosophy as [GitPod](https://www.gitpod.io/), [DevPod](https://devpod.sh/), [CodeSpaces](https://github.com/features/codespaces) or [CodeSandbox](https://codesandbox.io/), but self-hosted and probably a bit more old-school (uses `ssh`, no `docker` is involved, they feel like normal old-school Ubuntu VMs, with a near-zero learning curve).

## Features

- You and your team can start up new VMs just by SSH-ing into them.
- Works seamlessly with Visual Studio Code's official [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.
- Uses LXD containers, which share RAM, CPU and disk space, providing high VM density.
- There are "personal" and "shared" VMs. (Shared VMs are the ones starting with `demo-`. Personal ones with `username-`.)
- Port 80 of every VM is automatically accessible over HTTPS, like `https://demo-foo.example.com`. (A [reverse-proxy](https://caddyserver.com/v2) deals with TLS and forwards HTTP requests to the right VM.)
- Every subdomain is protected with HTTP password automatically, so forgetful humans don't accidentally expose random things to the world. (Can be disabled on a per-VM basis by `sudo touch /nopassword`.)
- The directory `/persist/` is shared between a user's personal VMs. (This makes file transfer easy.)
- VMs are considered ephemeral: by default all VMs "die" at night. (This protects resources from forgetful humans.)
- But files in `/persist/` are persistent and survive the nightly killing of VMs. (So it's recommended to keep your work there.)
- Some VMs can easily be marked to be "spared" from the nightly killing. (`sudo touch /nokill`)
- LXD containers are automatically configured to be `docker`-capable.
- By default VMs are running Ubuntu, but you can request different OSes just by procuring the VM like this: `ssh demo-foo-centos8.example.com` (Then on you can use just `demo-foo.example.com`.)
- Personal VMs are protected from other users, but can still be shared if a teammate's SSH key is put in `/home/user/.ssh/authorized_keys` by the VM's owner.
- EXPERIMENTAL: Using LXD's "real VMs" running on QEMU, as opposed to containers. (Not all features work with QEMU VMs, but they are real VMs. You can even install K8s on them.)

## How does it work?

- You install this an an Ubuntu server, and put a small snippet in your `.ssh/config`. (And your team members'.)
- When you SSH to a 🌳VMTREE VM, your SSH client resolves the VM name you requested to the same server, because of the wildcard DNS domain.
- Your `.ssh/config` snippet specifies to use a "jump" user called `vmtree` on the server. (Only the people who have their SSH key in this `vmtree` user's `authorized_keys` file can connect, of course.)
- The `vmtree` user's `authorized_keys` file force-runs the `/vmtree/vmtree.sh` script on the server. (It's not possible to run anything else via SSH with this user.)
- The SSH snippet in your `.ssh/config` passes name of the VM you requested to the `/vmtree/vmtree.sh` script.
- The `/vmtree/vmtree.sh` script does security checks regarding naming convention, etc.
- The `/vmtree/vmtree.sh` script starts an LXD container with the VM name you specified, passing it a `cloud-init` script that pre-configures the VM with your SSH key (and possibly other things).
- The `/vmtree/vmtree.sh` script waits for the VM to obtain an IP address and have SSH started.
- The `/vmtree/vmtree.sh` script connects your SSH session to the SSH port of the LXD container.
- You are in! You can use the LXD container just as you would with any other VM.

## Any disadvanteges?

Just a few.

- You will be asked twice for SSH authorization (once for the jump user, and once for the freshly created VM.)
- LXD containers _nearly_ full VMs, but have some security limits regarding mounting file systems, setting system parameters, etc. These rarely interfere with "normal" development. (And when they do, you can start _real_ QEMU VMs instead of LXD containers by specifying `-vm` as the 4th part of the VM name, like `ssh xx-myrealvm1-ubuntu2204-vm.example.com`). This is needed for example if you want to run a full Kubernetes cluster. (Docker and `docker-compose` work on LXD containers with the preconfiguration that these scripts already do for you.)

## Basic installation (using a self-signed certificate)

On an Ubuntu 20.04 or 22.04 server with a public IP address, run:

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
1. Get a powerful host server that you will use for VMTREE, running Ubuntu 22.04 or 20.04.
1. Configure DNS so `example.com` and `*.example.com` point to the host server's IP. (Wait until it propagates.)
1. On your host server, `sudo git clone https://github.com/kkovacs/vmtree.git /vmtree`
1. Copy your and your teams's SSH public keys (`authorized_keys` files) to `/vmtree/keys/<username>` files.
1. Run `sudo /vmtree/install.sh --skip-install` to do basic checks and generate a default `/vmtree/.env` file.
1. It will say that you need to fill out the `/vmtree/.env` file. Fill out:
   - your domain name (`example.com`)
   - your desired automatic HTTP AUTH username / password
   - your DNS provider and its token to use with acme.sh.
1. Run `sudo /vmtree/install.sh` again to finish the installation.
1. Distribute the snippet it prints out to your team, to put into their `.ssh/config` files.
