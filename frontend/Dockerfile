FROM nginxinc/nginx-unprivileged:1.30-alpine

# The image entrypoint fills ${BACKEND_HOST} / ${BACKEND_PORT} into this template at start-up
# and writes the result to /etc/nginx/conf.d/default.conf.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY index.html app.js styles.css /usr/share/nginx/html/

ENV BACKEND_HOST=backend \
    BACKEND_PORT=8000

EXPOSE 8080
