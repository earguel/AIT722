---
title: "Hexagon Layer Aggergation (AIT 722)"
author: "Myeong Lee"
output: html_document
---
This code is for processing and visualizing diverse geospatial polygons and aggregating from one layer to another when polygons are different. 

```{r}
library(ggmap)
library(ggplot2)
library(stringr)
library(readr)
library(dplyr)
library(sp)
library(rgeos)
library(rgdal)
library(raster)
library(classInt)
library(data.table)

setwd("D:/GitHub/AIT722/week5/data")
register_google(key='AIzaSyAanFoWwtldBOuq91AefwLwSGNJVFkUQwM')
#ggmap::register_google(key ='AIzaSyAmd1LCccpS67KWcVCc3OEZd8Yg8aj6DmQ')
get_googlemap("Fairfax County,VA", zoom = 12) %>% ggmap()
```


# Extracting Car2go's points data as SpatialPointsDataFrame
```{r}

total <- read_delim("data/car2go_samples.csv", delim = ",",col_names = T )
total$ID <- row.names(total)
total$ID <- as.integer(total$ID)
xy <- total[,c("lon","lat")]
points <- SpatialPointsDataFrame(coords = xy, data = total,
                               proj4string = CRS("+proj=longlat +datum=WGS84 +ellps=WGS84 +towgs84=0,0,0"))
plot(points)
```

# Loading polygons from KML and Shapefiles + Viz
```{r}

# DC Boundary as a polygon
dc_boundary <- readOGR("data/DC_Boundary/DC_Boundary.shp") %>% spTransform(CRS("+proj=longlat +datum=WGS84"))

map <- get_map(location = 'Washington DC', zoom = 11, color = "bw")
mapPoints <- ggmap(map) + geom_polygon(aes(x=long, y=lat, group=group), 
                                       data = dc_boundary, color='red', alpha=0.5) + ggtitle("DC Boundary")
mapPoints

# DC neighborhood boundaries 
gov_cluster <- readOGR("data/dc_neighborhood_boundaries_GovClusters.kml", 
                       layer="dc_neighborhood_boundaries_GovClusters") %>% 
                      spTransform(CRS("+proj=longlat +datum=WGS84"))

mapPoints <- ggmap(map) + geom_polygon(aes(x=long, y=lat, group=group), 
                                       data = gov_cluster, color='red', alpha=0.5) + ggtitle("Gov Clusters")
mapPoints

```


# Hexagon Generation (when want to come up with a new polygon layer)
```{r}

# Hexagons Generation
cell_diameter <- 0.007 
ext <- as(extent(dc_boundary) + cell_diameter, "SpatialPolygons")
projection(ext) <- projection(dc_boundary)
g <- spsample(ext, type = "hexagonal", cellsize = cell_diameter, offset = c(0.5, 0.5))
hex_grid <- HexPoints2SpatialPolygons(g, dx = cell_diameter)
hex_grid <- hex_grid[dc_boundary, ]


# Change SpatialPolygons to SpatialPolygonsDataFrame
row.names(hex_grid) <- as.character(1:length(hex_grid))
pid <- sapply(slot(hex_grid, "polygons"), function(x) slot(x, "ID"))
hex_df <- data.frame( hex_ID=1:length(hex_grid), row.names = pid)
hex_grid <- SpatialPolygonsDataFrame(hex_grid, hex_df)
hex_grid@data$area <- area(hex_grid)
hex_transform <- fortify(hex_grid)

mapPoints <- ggmap(map) + geom_polygon(aes(x=long, y=lat, group=group), data = hex_transform, color='red', alpha=0) + ggtitle("Hexagon Overlay")
mapPoints

# Saving Geospatial Polygons as GeoJSON (when you have a meaningful geospatial layer)
writeOGR(hex_grid, "hexagons.geojson", layer="polygons", driver="GeoJSON", check_exists = FALSE)

```


# Iterating through SpatialPolygonsDataFrame (neighborhood boundaries) for point aggregation
```{r}

# Intersecting between two layers to aggregate points to the polygon layer.
gov_cluster@data$polygon_id <- 1:nrow(gov_cluster@data) # Add "polygon_id" to gov_cluster SpatialPolygonsDataFrame
intersections <- raster::intersect(x = points, y = gov_cluster)

point_counts <- intersections@data %>% group_by(polygon_id) %>% 
  summarise(num_car_locations=n(), ave_fuel=mean(fuel))

gov_cluster@data <- gov_cluster@data %>% left_join(point_counts, by=c("polygon_id"))
view(hex_grid@data)

writeOGR(gov_cluster, "car2go_num_points.geojson", layer="polygons", driver="GeoJSON", check_exists = FALSE)

# For visualizing... you have to use `fortify` the followings..
lnd.f <- fortify(gov_cluster)
gov_cluster$id <- row.names(gov_cluster) # Add "id" 
lnd.f <- left_join(lnd.f, gov_cluster@data, by=("id"))

# Density Map
map <- get_map(location = 'Washinton DC', zoom = 11, color = "bw")
mapPoints <- ggmap(map) + 
  geom_polygon(aes(x=long, y=lat, group=group,
                   fill=num_car_locations), data = lnd.f ,
               alpha=0.9) + 
  scale_fill_continuous(low = "yellow", high = "red") + ggtitle("The number of cars")
mapPoints







# Another way.. using a FOR loop to traverse different hexagons
signature <- data.frame(matrix(ncol = 2, nrow = 0)) 
colnames(signature) <- c("id", "freq")


for(i in 1:nrow(hex_grid)) { 
  
  print(i)
  
  # Selecting points within the selected polygon (points --> polygon)
  tryCatch({
      intersection = raster::intersect(x = points, y = hex_grid[i,])
    }, error = function(e) {
      # add 0 for ids with no intersection
    })
  
  
  # If no intersection found, skip.
  if (nrow(intersection@data) == 0) next
  
  intersection@data$id = i
  freq_table <- intersection@data %>% dplyr::group_by(id) %>% summarise(freq=n())
  
  signature <- rbind(signature, freq_table)

}


```


# Color Gradiation based on Freq (Polygon Viz as Density Map)
```{r}

temp_layer <- hex_grid
row.names(temp_layer) <- as.character(1:length(temp_layer))
temp_layer$ID <- row.names(temp_layer)

signature$id <- as.character(signature$id)
temp_layer@data <- temp_layer@data %>% left_join(signature, by = c("ID" = "id"))
temp_layer@data$freq[is.na(temp_layer@data$freq)] <- 0

lnd <- SpatialPolygonsDataFrame(Sr = spTransform(temp_layer, CRSobj = CRS("+init=epsg:4326")), data = temp_layer@data)
lnd.f <- fortify(lnd)
lnd$id <- row.names(lnd)
lnd.f <- left_join(lnd.f, lnd@data, by=("id"))

# Density Map
map <- get_map(location = 'Washinton DC', zoom = 11, color = "bw")
mapPoints <- ggmap(map) + geom_polygon(aes(x=long, y=lat, group=group, fill=(freq)), data = lnd.f , alpha=0.9) + scale_fill_continuous(low = "yellow", high = "red") + ggtitle("Hexagon Layer")
mapPoints

writeOGR(lnd, "hexagons_freq.geojson", layer="polygons", driver="GeoJSON", check_exists = FALSE)

```


* Clustering of the hexagon layers becomes possinble if you associate a layer (bag-of-words model) to each hexagon.
* Then, you can group the hexagons together to show neighborhoods.
* Class activities: 
  (1) Write scripts to create a time-series data (24-hours array) for each hexagon.
  (2) Run the K-means clustering.
