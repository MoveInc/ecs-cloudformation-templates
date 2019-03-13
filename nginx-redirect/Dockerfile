FROM nginx:alpine
EXPOSE 80
ADD start.sh /usr/local/bin
ADD nginx-default.conf /etc/nginx/conf.d/default.conf
CMD ["/usr/local/bin/start.sh"]
