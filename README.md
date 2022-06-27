# 🌳VMTREE is an easy way to make ephemeral VMs.

This is a collection of scripts that turn a server into a "VM tree", on which you can start up (and delete) ephemeral [LXD containers](https://linuxcontainers.org/lxd/) -- basically VMs.

The way to procure a new VM is just to SSH into it. `ssh dev-foo.example.com` starts up a fresh VM called `dev-foo` and connects to it. `sudo touch /killme` destroys it.

Our dev(ops) team has been using it for years, and we ❤️ that fresh VMs just grow on the "VM tree" for easy picking.

## Features

- Devs can start up new VMs just by SSH-ing into them.
- Uses LXD containers, which share RAM, CPU and disk space, providing high VM density.
- There are "personal" and "shared" VMs. (Shared VMs are the ones starting with `dev-`. Personal ones with `username-`.)
- Port 80 of every VM is automatically accessible over HTTPS, like `https://dev-foo.example.com`. (A [reverse-proxy](https://caddyserver.com/v2) deals with TLS and forwards HTTP requests to the right VM.)
- A HTTP password protects every subdomain automatically, so forgetful humans don't accidentally expose random things to the world. (This can be easily disabled on a per-VM basis.)
- The directory `/persist/` is shared between a user's personal VMs. (This makes file transfer easy.)
- VMs are considered ephemeral: by default all VMs "die" at 6am. (This protects resources from forgetful humans.)
- But files in `/persist/` are persistent and survive the 6am killing of VMs. (So it's recommended to keep your work there.)
- Some VMs can easily be marked to be "spared" from the 6am killing. (`sudo touch /nokill`)
- LXD containers are automatically configured to be `docker`-capable.
- By default VMs are running Ubuntu 22.04, but you can request different OSes just by procuring the VM like this: `ssh dev-foo-centos8.example.com` (Then on you can use just `dev-foo.example.com`.)
- Personal VMs are protected from other users, but can still be shared if a teammate's SSH key is put in `/home/user/.ssh/authorized_keys` by the VM's owner.
- EXPERIMENTAL: Using LXD's "real VMs" running on QEMU, as opposed to containers. (Not all features work with QEMU VMs, but they are real VMs. You can even install K8s on them.)

## Installation (basic)

On an Ubuntu 20.04 or 22.04 server with a public IP address, run:

```bash
sudo git clone https://github.com/kkovacs/vmtree.git /vmtree
sudo cp ~/.ssh/authorized_keys /vmtree/keys/my
sudo /vmtree/install.sh
```

Then put the snippet it prints out in your `.ssh/config` file (on your PC, not on the server, of course).

This basic setup will use [ip.me](https://ip.me/), [nip.io](https://nip.io/), and a self-signed certificate to set up the fullest possible functionality without using your own domain.

## Installation (full featured with valid wildcard certificate)

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
