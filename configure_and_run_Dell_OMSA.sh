#!/bin/sh

if [ "" = "${OMSA_username}" -o "" = "${OMSA_password}" ]; then
	echo "Please specify OMSA_username and OMSA_password env vars."
	exit 1;
fi;

# Set login credentials
USER_EXISTS=`cat /etc/passwd | grep -i "^${OMSA_username}:"`
if [ "${USER_EXISTS}" = "" ]; then
	echo "Creating user ${OMSA_username}..."
	adduser "${OMSA_username}"
fi;

echo "Setting Dell OMSA credentials for user \"${OMSA_username}\"..."
echo "$OMSA_username:$OMSA_password" | chpasswd

echo "Allowing \"${OMSA_username}\" user to access Dell OMSA..."
echo "${OMSA_username}    *       Administrator" > /opt/dell/srvadmin/etc/omarolemap

echo "Setting up OMSA service..."
echo "#!/bin/sh" > /etc/rc.local
echo "/opt/dell/srvadmin/sbin/srvadmin-services.sh enable" >> /etc/rc.local
echo "/opt/dell/srvadmin/sbin/srvadmin-services.sh restart" >> /etc/rc.local
chmod a+x /etc/rc.local

# Remove some things we don't want system starting.
if [ -e /usr/lib/systemd/system/getty@.service ]; then
	rm -Rfv /usr/lib/systemd/system/getty@.service
fi

if [ -e /usr/lib/systemd/system/autovt@.service ]; then
	rm -Rfv /usr/lib/systemd/system/autovt@.service
fi

# echo "Enabling all Dell OMSA services..."
# /opt/dell/srvadmin/sbin/srvadmin-services.sh enable
#/opt/dell/srvadmin/sbin/srvadmin-services.sh is-enabled

echo "Enabling rc.local service..."
systemctl enable rc-local.service

echo "Starting init..."
exec /sbin/init
