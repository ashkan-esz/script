sudo apt update
sudo apt upgrade -y 
sudo apt install htop curl -y

sudo useradd -m "mahdi"
echo "mahdi:111111" | sudo chpasswd

sudo useradd -m "amene"
echo "amene:amene2828" | sudo chpasswd

sudo useradd -m "mivechi"
echo "mivechi:mivechi2828" | sudo chpasswd

sudo useradd -m "zandaii"
echo "zandaii:zandaii2828" | sudo chpasswd

sudo useradd -m "fateme"
echo "fateme:fateme8282" | sudo chpasswd

bash <(curl -Ls https://raw.githubusercontent.com/xpanel-cp/XPanel-SSH-User-Management/master/TCP-Tweaker --ipv4)

bash <(curl -Ls https://raw.githubusercontent.com/mahmoud-ap/rocket-ssh/master/block-ir-ip.sh --ipv4)
