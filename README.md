# Dell_OMSA_Docker

Dell OpenManage Server Administrator in Docker.

This is loosely based on https://hub.docker.com/r/jdelaros1/openmanage/ but updated for a newer version of OMSA. (20.02)

Currently this is a bit icky because it runs systemd within the container to get openmanage to start, but it does the job for now.

No SNMP support, maybe later.

## Running

This can be ran with something like:

```bash
docker run -d \
    --privileged \
    --restart=unless-stopped \
    -e OMSA_username="SomeUsername" \
    -e OMSA_password="SomePassword" \
    -v /lib/modules/`uname -r`:/lib/modules/`uname -r` \
    -p 1311:1311 \
    --name=Dell_OMSA tigerblue77/Dell_OMSA
```

And you can then query things with something like:

```sh
docker exec Dell_OMSA omreport chassis bios
```
