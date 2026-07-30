Substitua o arquivo de configuração original (vpn-box.apkovl.tar.gz) na raíz do cartão, conforme achar necessário:

* basic_vpn-box.apkovl.tar.gz:
Configuração básica, apenas o vpn, a conexão pode vir tanto pela porta ethernet(eth0) como pelo wireless (wlan0)

* AP_vpn-box.apkovl.tar.gz:
Usa a interface Wireless como um Access Point (AP), neste caso o arquivo wifi.conf na raíz do cartão será usado para definir o nome da rede e senha de acesso.

* wifi-adapter_vpn-box.apkovl.tar.gz
Usa a interface ethernet para saída de conexão, atuando como um adaptador wifi. Neste caso é necessário que o arquivo wifi.conf esteja correto e o wifi funcionando.

* wifi-adapter-AP_vpn-box.apkovl.tar.gz
Igual ao "wifi-adapter" mas cria também um AP com o nome da rede original + "_rep" e a mesma senha.

OBS:

** A porta de conexão usada deve ser definida no arquivo firewall.txt na pasta wireguard
** Caso o arquivo wifi.conf seja apagado, ele será recriado no próximo reboot.
** A variável "CNL" (canal) no arquivo wifi.conf, só é usado caso esteja setado como modo AP, e mesmo assim não é obrigatório, use apenas se o canal 6 esteja com problemas.
