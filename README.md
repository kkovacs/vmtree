# 🌳VMTREE is an easy way to make ephemeral VMs.

This is a collection of scripts that turn a server into a "VM tree", on which you can start up (and delete) ephemeral [LXD containers](https://linuxcontainers.org/lxd/) -- basically VMs.

The way to procure a new VM is just to SSH into it. `ssh dev-foo.example.com` starts up a fresh VM called `dev-foo` and connects to it. `sudo touch /killme` destroys it.

Our dev(ops) team has been using it for years, and we ❤️ that fresh VMs just grow on the "VM tree" for easy picking.

## Features

- Devs can start up new VMs just by SSH-ing into them.
- Uses LXD containers, which share RAM, CPU and disk space, providing high VM density.
- There are "personal" and "shared" VMs. (Shared VMs are the ones starting with `dev-`. Personal ones with `username-`.)
- Port 80 of every VM is automatically accessible over HTTPS, like `https://dev-foo.example.com`. (A reverse-proxy deals with TLS and forwards HTTP requests to the right VM.)
- The directory `/persist/` is shared between a user's personal VMs. (This makes file transfer easy.)
- VMs are considered ephemeral: by default all VMs "die" at 6am. (This protects resources from forgetful humans.)
- But files in `/persist/` are persistent and survive the 6am killing of VMs. (So it's recommended to keep your work there.)
- Some VMs can easily be marked to be "spared" from the 6am killing.
- A HTTP password protects every subdomain automatically, so forgetful humans don't accidentally publish random things to the world. (This can easily be disabled on a per-VM basis.)
- LXD containers are automatically configured so `docker` can run in them.

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
   - your DNS provider and its token to use with acme.sh.
1. Run `sudo /vmtree/install.sh` again to finish the installation.
1. Distribute the snippet it prints out to your team, to put into their `.ssh/config` files.
