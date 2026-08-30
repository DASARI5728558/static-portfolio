# Use a lightweight nginx image to serve static files
FROM nginx:alpine

# Remove default nginx welcome page
RUN rm -rf /usr/share/nginx/html/*

# Copy site files into nginx's default serving directory
COPY index.html /usr/share/nginx/html/
COPY style.css /usr/share/nginx/html/

# Expose port 80
EXPOSE 80

# Nginx runs in the foreground by default in this base image
CMD ["nginx", "-g", "daemon off;"]
