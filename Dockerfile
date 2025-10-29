# Use the official Nginx image as the base image.
# Using a specific version like 1.28 ensures that the build is reproducible.
FROM nginx:1.28

# Copy the website files (HTML, images, and CV) into the Nginx container.
# These files will be served by the Nginx web server.
COPY index.html main.png SurajRauniyarCV.pdf /usr/share/nginx/html/

# Expose port 80 to allow incoming HTTP traffic.
# This is the standard port for HTTP.
EXPOSE 80
