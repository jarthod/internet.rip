# (×\_×) Internet.RIP (or RIPinter.net)

The purpose of this this small Rails application is to provider a simple & high-level status page for the internet.

## Run locally

```sh
bundle install
bin/rails s
```

## World Map

The background SVG world map comes from https://simplemaps.com/resources/svg-world, on which we apply some fixes for inconsistencies in the `data/simplemaps/process_map.rb` script. So if the map needs updating, we should update the file in `data/simplemaps` and then run the script again to generate the processed version in `lib/assets/images`.

The Robinson projection has been fine-tuned for this map (which is unfortunately cropped on the sides), so in case of updates, it would be a good idea to verify the coordinates grid alignement again.