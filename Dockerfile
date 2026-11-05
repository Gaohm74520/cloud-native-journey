FROM nginx
RUN echo '<h1>这个镜像由 CI 自动构建</h1>' > /usr/share/nginx/html/index.html
EXPOSE 80
