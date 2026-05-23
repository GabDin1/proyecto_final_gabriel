#!/bin/bash

BASE="/media/sf_reportes_maquinas_virtuales"
OUT="$BASE/mitigacion_aplicada_documentada.txt"
TMP="/tmp/mitigacion_aplicada_documentada.txt"
NEW_DB_PASS="WP_$(date +%Y%m%d%H%M%S)_Seguro!"

if [ "$EUID" -ne 0 ]; then
  echo "Ejecuta este script con sudo:"
  echo "sudo bash ~/mitigar_servidor_y_documentar.sh"
  exit 1
fi

if [ ! -d "$BASE" ]; then
  BASE="$HOME/forense"
  mkdir -p "$BASE"
  OUT="$BASE/mitigacion_aplicada_documentada.txt"
fi

exec > >(tee "$TMP") 2>&1

titulo() {
  echo
  echo "================================================="
  echo "$1"
  echo "================================================="
}

cmd() {
  echo
  echo "COMANDO:"
  echo "$ $1"
  echo
  echo "RESULTADO:"
  eval "$1"
}

echo "INICIO MITIGACION COMPLETA"
date

titulo "1. ESTADO INICIAL"
echo "Se revisan los puertos y servicios activos antes de aplicar de nuevo las mitigaciones."
cmd "ss -tulnp"

titulo "2. ENDURECIMIENTO DE SSH"
echo "Se deshabilita el acceso remoto como root y la autenticación por contraseña."
cmd "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
cmd "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
cmd "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
cmd "grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config"
cmd "grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config"
cmd "systemctl restart ssh"
cmd "sshd -T | grep -E 'permitrootlogin|passwordauthentication'"

titulo "3. CONFIGURACION SEGURA DE FTP"
echo "Se deshabilita el acceso anonymous en vsftpd."
if [ -f /etc/vsftpd.conf ]; then
  cmd "cp /etc/vsftpd.conf /etc/vsftpd.conf.bak.$(date +%Y%m%d_%H%M%S)"
  cmd "sed -i 's/^#\\?anonymous_enable=.*/anonymous_enable=NO/' /etc/vsftpd.conf"
  cmd "grep -q '^anonymous_enable' /etc/vsftpd.conf || echo 'anonymous_enable=NO' >> /etc/vsftpd.conf"
  cmd "grep -E 'anonymous_enable|write_enable|local_enable' /etc/vsftpd.conf"
else
  echo "No existe /etc/vsftpd.conf. Se omite esta parte."
fi

titulo "4. CORRECCION DE PERMISOS WORDPRESS"
echo "Se eliminan permisos excesivos y se protege wp-config.php."
cmd "find /var/www/html -type d -exec chmod 755 {} \\;"
cmd "find /var/www/html -type f -exec chmod 644 {} \\;"
cmd "chmod 600 /var/www/html/wp-config.php"
cmd "stat /var/www/html/wp-config.php"
echo "Conclusión: wp-config.php queda en 0600, accesible solo por el propietario y root."

titulo "5. CAMBIO PASSWORD MYSQL/WORDPRESS"
echo "Se sustituye la contraseña débil de WordPress/MariaDB por una robusta."
cmd "mysql -e \"ALTER USER 'wordpressuser'@'localhost' IDENTIFIED BY '$NEW_DB_PASS'; FLUSH PRIVILEGES;\""
cmd "cp /var/www/html/wp-config.php /var/www/html/wp-config.php.bak.$(date +%Y%m%d_%H%M%S)"
cmd "sed -i \"s/define( 'DB_PASSWORD', '.*' );/define( 'DB_PASSWORD', '$NEW_DB_PASS' );/\" /var/www/html/wp-config.php"
cmd "grep 'DB_PASSWORD' /var/www/html/wp-config.php"

titulo "6. DESHABILITAR XMLRPC"
echo "Se deshabilita xmlrpc.php para reducir ataques de fuerza bruta y abuso de pingbacks."
cmd "if [ -f /var/www/html/xmlrpc.php ]; then mv /var/www/html/xmlrpc.php /var/www/html/xmlrpc.php.disabled; fi"
cmd "ls -lah /var/www/html/xmlrpc.php* 2>/dev/null || true"

titulo "7. HARDENING APACHE INDEXES"
echo "Se deshabilita el listado automático de directorios en Apache."
cmd "cp /etc/apache2/apache2.conf /etc/apache2/apache2.conf.bak.$(date +%Y%m%d_%H%M%S)"
cmd "sed -i 's/Options Indexes FollowSymLinks/Options -Indexes +FollowSymLinks/g' /etc/apache2/apache2.conf"
cmd "systemctl restart apache2"
cmd "grep -R 'Options' /etc/apache2 | grep Indexes || true"
echo "Conclusión: Options -Indexes evita que Apache liste archivos internos."

titulo "8. DESHABILITAR SERVICIOS INNECESARIOS"
echo "Se detienen y deshabilitan servicios no necesarios para un servidor WordPress."
for svc in avahi-daemon cups exim4; do
  echo
  echo "Servicio: $svc"
  cmd "systemctl stop $svc 2>/dev/null || true"
  cmd "systemctl disable $svc 2>/dev/null || true"
  cmd "systemctl status $svc --no-pager | head -10 || true"
done

titulo "9. DESHABILITAR FTP COMPLETAMENTE"
echo "Se apaga vsftpd para cerrar el puerto 21 y eliminar la superficie FTP."
cmd "systemctl stop vsftpd 2>/dev/null || true"
cmd "systemctl disable vsftpd 2>/dev/null || true"
cmd "systemctl status vsftpd --no-pager | head -10 || true"
cmd "nc -zv localhost 21 || true"

titulo "10. VALIDACION SFTP"
echo "Se confirma SFTP como alternativa segura a FTP usando OpenSSH."
cmd "sshd -T | grep sftp"

titulo "11. ESTADO FINAL DE PUERTOS"
echo "Se valida que solo quedan activos los servicios necesarios."
cmd "ss -tulnp"

titulo "12. VALIDACIONES FINALES"
echo "Validación SSH:"
cmd "sshd -T | grep -E 'permitrootlogin|passwordauthentication'"

echo "Validación FTP:"
cmd "nc -zv localhost 21 || true"

echo "Validación Avahi:"
cmd "ss -tulnp | grep 5353 || echo 'Puerto 5353 cerrado'"

echo "Validación CUPS:"
cmd "ss -tulnp | grep 631 || echo 'Puerto 631 cerrado'"

echo "Validación Exim:"
cmd "ss -tulnp | grep ':25' || echo 'Puerto 25 cerrado'"

echo "Validación wp-config.php:"
cmd "stat /var/www/html/wp-config.php"

echo "FIN MITIGACION COMPLETA"
date

awk '{ printf "%s\r\n", $0 }' "$TMP" > "$OUT"

echo
echo "Documento generado:"
echo "$OUT"
