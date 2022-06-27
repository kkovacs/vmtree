# 🌳VMTREE is a fast & easy way to procure ephemeral VMs.

This is a collection of scripts that turn a server into a "VM tree", on which you can start up (and delete) ephemeral [LXD containers](https://linuxcontainers.org/lxd/) -- basically VMs.

The way to procure a new VM is just to SSH into it. SSH-ing to a new one creates it.

Our dev(ops) team has been using it for years, and we ❤️ it.

## Features

- Developers can start up new VMs just by SSH-ing. (Running `ssh dev-foo.example.com` starts up a VM called `dev-foo` and connects you to it.)
- Uses LXD containers, which share RAM, CPU and disk space, providing high VM density.
- There are "personal" VMs, and "shared" VMs. (Shared VMs are the ones starting with `dev-`.)
- Port 80 of every VM is publicly accessible over HTTPS, for example at `https://dev-foo.example.com`. (A reverse proxy deals with TLS and forwards HTTP requests to the right VM.)
- A persistent mount in `/persist/` is shared between your personal VMs. (This makes file transfer easy.)
- VMs are considered ephemeral: by default all VMs "die" at 6am. (This protects resources from forgetful humans.)
- But files in `/persist/` survive the 6am killing of VMs, so it's recommended to keep your work there.
- LXD containers are automatically configured so you can run `docker` in them.
- An automatic HTTP AUTH protects every subdomain, so forgetful humans don't accidentally publish secrets to the world. (This can easily be disabled on a per-VM basis.)

## Installation (basic)

```bash
sudo git clone https://github.com/kkovacs/vmtree.git /vmtree
sudo /vmtree/install.sh
```

Then put the snippet it prints to your `.ssh/config` file.

## Installation (full featured with valid wildcard certificate)

1. Get a domain that you will use for VMTREE. (From now on: `example.com`).
1. Host the domain on a provider supported by [acme.sh](https://github.com/acmesh-official/acme.sh/wiki/dnsapi). (Needed for the wildcard TLS certificate.)
1. Get a powerful host server that you will use for VMTREE.
1. Configure DNS so `example.com` and `*.example.com` point to the host server's IP. (Wait until it propagates.)
1. On your host server, `sudo git clone https://github.com/kkovacs/vmtree.git /vmtree`
1. Copy your and your teams's SSH public keys (`authorized_keys` files) to `/vmtree/keys/<username>` files.
1. Run `sudo /vmtree/install.sh` to do basic checks.
1. It will say that you need to fill out the `/vmtree/.env` file. Fill out:
   - your domain name (`example.com`)
   - your desired automatic HTTP AUTH username / password
   - your DNS provider and it's token to use with acme.sh.
1. Run `sudo /vmtree/install.sh` again to finish the installation.
1. Distribute the snippet it prints out to your team, to put into their `.ssh/config` files.
