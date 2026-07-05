FROM nginx:1.27-alpine

COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf

# Only the public/ folder is needed to serve Laravel's front controller + assets
COPY public/ /var/www/html/public/

EXPOSE 80
