1 - Formate o cartão SD do dispositivo como FAT32
2 - Copie todos estes arquivos na raíz do cartão
3 - Instale o uboot:
	sudo dd if=u-boot-orange_pi_X.bin of=/dev/sdX bs=8k seek=1
4 - Se quiser usar wifi, edite o arquivo wifi.conf
5 - Configure a vpn na pasta wireguard

6 - Acesse o dispositivo pelo nome: vpn-box.local
7 - Acesso ssh: root passwd = zaq12wsx
