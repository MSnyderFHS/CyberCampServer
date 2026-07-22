PANTHER PRANK ARCHIVE — UBUNTU/Nginx INSTALLATION

This folder is a self-contained static website. It requires no Node.js,
database, build tools, or internet connection.

Recommended hosting method: Nginx

1. Install Nginx:
   sudo apt update
   sudo apt install nginx

2. Copy this folder's contents into the web root:
   sudo mkdir -p /var/www/panther-pranks
   sudo cp -r ./* /var/www/panther-pranks/

3. Create /etc/nginx/sites-available/panther-pranks with:

   server {
       listen 80 default_server;
       listen [::]:80 default_server;
       root /var/www/panther-pranks;
       index index.html;
       server_name _;

       location / {
           try_files $uri $uri/ =404;
       }
   }

4. Enable the site (remove Ubuntu's default site if it is still enabled):
   sudo rm -f /etc/nginx/sites-enabled/default
   sudo ln -s /etc/nginx/sites-available/panther-pranks /etc/nginx/sites-enabled/panther-pranks
   sudo nginx -t
   sudo systemctl reload nginx

The hidden camper clue is stored as the data-classified-next-step attribute on
the page's <main> element. It is not displayed normally, but campers can find
it in Browser Developer Tools by inspecting the page and searching for telnet.

The clue currently directs campers to TCP port 23 on the same server.
