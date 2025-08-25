FROM nginx:1.28

# Copy your custom HTML and CSS into the container and files
COPY index.html main.png SurajRauniyarCV.pdf /usr/share/nginx/html/

# Expose port 80
EXPOSE 80