FROM nginx:latest

# Copy your custom HTML and CSS into the container
COPY index.html main.png SurajRauniyarCV.pdf /usr/share/nginx/html/

# Expose port 80
EXPOSE 80