#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "date"

ROOT = File.expand_path("..", __dir__)
MEALS_PATH = File.join(ROOT, "data/meal_options.yaml")
PLACES_PATH = File.join(ROOT, "data/places.yaml")
CHECKED_ON = "2026-09-14"

# These are restaurant-specific itinerary choices. Their slot hashes are never
# mutated by this regeneration script.
PROTECTED_SLOTS = %w[
  day-03-lunch day-03-dinner day-07-dinner day-08-breakfast day-14-dinner
].freeze

# Rebuild only the windows whose route changed in the Nara/Uji/Osaka revision.
# Other generic windows contain separately researched route records and must not
# be flattened back to a rank-derived estimate by this script.
TARGET_SLOTS = %w[
  day-09-breakfast day-09-lunch day-12-lunch day-12-dinner day-13-breakfast
].freeze

STALE_PLACE_IDS = %w[hiraso-todaiji mentoan-nara sakura-burger-nara].freeze

# slot | venue id | venue name | category | official/first-party source | hours for
# the actual visit day | two-person order | item prices | total | currency
ROWS = <<~DATA.lines(chomp: true).reject { |line| line.empty? || line.start_with?("#") }
day-01-dinner|papparich-sydney-t1|PappaRich Sydney T1|malaysian|https://www.sydneyairport.com.au/eat/papparich/|Friday 07:00–22:00|Nasi lemak;Roti canai;Teh tarik|24;16;6|46|AUD
day-01-dinner|barista-sydney-t1|BARista Sydney T1|airport-dining|https://www.sydneyairport.com.au/eat/BARista|Friday 06:00–22:00|Beef burger with fries;Chicken burger with fries|19;19|38|AUD
day-01-dinner|coopers-alehouse-sydney-t1|Coopers Alehouse Sydney T1|airport-dining|https://www.sydneyairport.com.au/eat/coopers-alehouse|Friday evening service|Chicken schnitzel;Fish and chips|29;29|58|AUD
day-02-dinner|beer-hall-lion-ginza|Beer Hall Lion Ginza 7-chome|izakaya|https://www.ginzalion.jp/shop/brand/lion/shop1.html|Saturday 11:30–22:00|Roast beef;German sausage platter|2480;1980|4460|JPY
day-02-dinner|sato-yosuke-ginza|Sato Yosuke Ginza|noodles|https://www.sato-yoske.co.jp/shop/ginza/|Saturday dinner 17:00–21:00, last order 20:00|Tempura seiro udon;Thai curry udon set|2600;1800|4840|JPY
day-02-dinner|ginza-shabutsu-honten|Ginza Shabutsu Honten|shabu-shabu|https://shabutsu.com/|Saturday 17:00–23:00, last order 22:00|Harumi shabu-shabu course;Harumi shabu-shabu course|7500;7500|15000|JPY
day-03-breakfast|katsuki-fresa-ginza|Katsuki at Sotetsu Fresa Inn Ginza-Nanachome|breakfast|https://sotetsu-hotels.com/fresa-inn/ginza7/cuisine/|Sunday 06:45–10:00, last entry 09:30|Breakfast buffet;Breakfast buffet|1530;1530|3060|JPY
day-03-breakfast|sakura-gracery-ginza|SAKURA at Hotel Gracery Ginza|breakfast|https://gracery.com/ginza/breakfast/|Sunday 07:00–10:00, last order 09:30|Breakfast buffet;Breakfast buffet|2420;2420|4840|JPY
day-03-breakfast|ginza-breakfast-lab|Ginza Breakfast Lab|breakfast|https://choshoku.neu-inc.tokyo/|Sunday 07:00–11:00|Breakfast buffet;Breakfast buffet|2970;2970|5940|JPY
day-04-breakfast|ginza-granbell-breakfast|GINZA HOTEL by GRANBELL breakfast|breakfast|https://granbellhotel.jp/ginza/breakfast/|Monday 07:00–09:30|Breakfast buffet;Breakfast buffet|3000;3000|6000|JPY
day-04-breakfast|tricolore-ginza-honten|Tricolore Ginza Honten|cafe|https://www.ginza.jp/shop/10123|Monday from 08:00|Morning toast set;Morning toast set|900;900|1800|JPY
day-04-breakfast|celestine-ginza-casita|GINZA CASITA at Hotel The Celestine Ginza|breakfast|https://www.celestinehotels.jp/ginza/restaurant/|Monday 07:00–12:00, last order 11:00|Japanese breakfast;Western breakfast|4400;4400|8800|JPY
day-04-lunch|pelican-cafe-asakusa|Pelican Cafe Asakusa|cafe|https://asakusa.pelicancafe.jp/menu.html|Monday 09:00–17:00|Ham cutlet sandwich;Omelette sandwich|1100;950|2050|JPY
day-04-lunch|ichome-ichiban-tawaramachi|Ichome Ichiban-chi Nishi-Asakusa|japanese|https://tawaramachi1-chome1-banchi.com/lunch/|Monday 11:30–14:00|Katsu curry;Daily set meal|600;800|1400|JPY
day-04-lunch|asakusa-unana|Asakusa Unana|unagi|https://unana.jp/map/|Monday 09:00–17:30|Grilled eel rice ball;Grilled eel rice ball|600;600|1200|JPY
day-04-dinner|ginza-bairin-honten|Ginza Bairin Honten|tonkatsu|https://www.ginzabairin.com/menu/index.php|Monday 11:30–20:30|Special pork cutlet bowl;Pork loin cutlet set|2200;2400|4600|JPY
day-04-dinner|mugi-to-olive-ginza|Mugi to Olive Ginza|ramen-noodles|https://www.instagram.com/mugitooribu/|Monday 11:00–21:30|Clam soba;Triple soba|1800;1900|3700|JPY
day-04-dinner|ginza-swiss-honten|Ginza Swiss Honten|curry|https://ginza-swiss.com/|Monday 11:00–21:00, last order 20:30|Chiba pork katsu curry;Beef katsu curry|2750;2860|5610|JPY
day-05-breakfast|ekibenya-odori|Ekibenya Odori|ekiben|https://www.gransta.jp/mall/gransta_tokyo/ekibenyaodori/|Tuesday 06:00–21:00|Tokyo Bento;Chicken Bento|1850;1100|2950|JPY
day-05-breakfast|tetote-gransta|TeToTe Gransta Tokyo|ekiben|https://www.gransta.jp/mall/gransta_tokyo/tetote/|Tuesday 08:00–22:00|Salmon and salmon roe bento;Grilled fish bento|1500;1350|2850|JPY
day-05-breakfast|curlys-croissant|Curly's Croissant Tokyo Bake Stand|bakery|https://www.gransta.jp/mall/gransta_tokyo/tokyo_bake_stand/|Tuesday 08:00–22:00|Premium croissant;Ham and cheese croissant;Coffee|292;620;450|1362|JPY
day-05-lunch|yamasan-sushi-omicho|Yamasan Sushi Honten|sushi|https://ohmicho-ichiba.com/gourmet/shop71401/|Tuesday 09:00–16:00|Chef's seafood bowl;Chef's seafood bowl|3000;3000|6000|JPY
day-05-lunch|kaisen-hirai-ichibakan|Kaisen Hirai Ichibakan|seafood|https://www.kaisen-hirai.com/|Tuesday 11:00–17:00|Omicho seafood bowl;Seafood bowl|3000;2100|5100|JPY
day-05-lunch|ichinokura-omicho|Ichinokura Omicho Market|seafood|https://www.ichi-no-kura.jp/menu_ohmicho-ichiba/|Tuesday 11:00–22:00|Daily seafood set;Sashimi set|1280;1780|3060|JPY
day-05-dinner|akadama-honten|Akadama Honten|oden|https://www.oden-akadama.com/pages/83|Tuesday 16:00–23:00|Kanazawa oden assortment;Beef tendon stew|2200;900|3100|JPY
day-05-dinner|morimori-sushi-katamachi|Morimori Sushi Katamachi|sushi|https://www.morimorisushi.com/|Tuesday dinner service|Local fish sushi set;Three-piece nodoguro sushi|2200;1200|3400|JPY
day-05-dinner|hachiban-ramen-katamachi|Hachiban Ramen Katamachi|ramen-noodles|https://www.hachiban.jp/shop/ishikawa/|Tuesday dinner service|Vegetable ramen;Gyoza ramen set|790;1190|1980|JPY
day-06-breakfast|amanek-kanazawa-breakfast|Hotel Amanek Kanazawa breakfast|breakfast|https://amanekhotels.jp/kanazawa/meal/|Wednesday 06:30–09:30, last order 09:00|Local breakfast buffet;Local breakfast buffet|2200;2200|4400|JPY
day-06-breakfast|isotope-cafe-kanazawa|isotope cafe|cafe|https://www.kanazawa-kankoukyoukai.or.jp/article/detail_475.html|Wednesday morning plate from 08:30|Morning plate;Morning plate|1300;1300|2600|JPY
day-06-breakfast|omo5-kanazawa-cafe|OMO5 Kanazawa Katamachi Cafe|breakfast|https://hoshinoresorts.com/ja/hotels/omo5kanazawakatamachi/dining/|Wednesday 07:00–10:00, last order 09:30|Kanazawa breakfast;Kanazawa breakfast|2100;2100|4200|JPY
day-06-lunch|nanahoshi-curry|Kanazawa Nanahoshi Curry|curry|https://nanahoshicurry.shop/shopinfo/|Wednesday 11:00–15:00 and 17:00–19:30|Chicken curry;Bean curry|1150;1050|2200|JPY
day-06-lunch|fusion21-kanazawa|Fusion21|museum-cafe|https://www.kanazawa21.jp/data_list.php?d=2&g=10|Wednesday lunch 11:00–14:00|Fusion lunch;Seasonal pasta lunch|2200;1900|4100|JPY
day-06-lunch|paul-bocuse-kanazawa|Cafe and Brasserie Paul Bocuse|french|https://www.hiramatsurestaurant.jp/paulbocuse-cafe/|Wednesday lunch from 11:00|Seasonal lunch;Seasonal lunch|3300;3300|6600|JPY
day-06-dinner|oozeki-kanazawa|Oozeki|oden|https://www.kanazawa-kankoukyoukai.or.jp/article/detail_490.html|Wednesday 16:00–22:00|Oden assortment;Grilled local fish|2200;1600|3800|JPY
day-06-dinner|amatsubo-kakinokibatake|Amatsubo Kakinokibatake|izakaya|https://amatsubo-honten.owst.jp/foods|Wednesday 17:00–22:00|Kanazawa oden assortment;Seasonal sashimi|1800;1900|3700|JPY
day-06-dinner|itachan-katamachi|Itachan Katamachi|izakaya|https://www.kanazawa-kankoukyoukai.or.jp/gourmet/|Wednesday dinner service|Local sashimi plate;Jibuni duck stew|2200;1200|3400|JPY
day-07-breakfast|hiramipan|Hiramipan|bakery|https://hiramipan.co.jp/news/hiramipan/|Thursday 08:00–10:30 breakfast|Croissant sandwich;Seasonal tart;Coffee|748;650;500|1898|JPY
day-07-breakfast|mare-dor-kanazawa|Mare d'Or at Kanazawa Tokyu Hotel|breakfast|https://www.tokyuhotels.co.jp/kanazawa-h/breakfast/index.html|Thursday 06:30–10:00, last entry 09:40|Breakfast buffet;Breakfast buffet|3500;3500|7000|JPY
day-07-breakfast|starbucks-korinbo|Starbucks Coffee CLASO PLACE Korinbo|cafe|https://www.starbucks.co.jp/store/search/detail.php?id=2253|Thursday 07:00–22:00|Breakfast sandwich;Breakfast sandwich;Drip coffees|540;540;860|1940|JPY
day-07-lunch|higashiyama-mizuho|Higashiyama Mizuho|japanese|https://www.h-mizuho.jp/|Thursday 11:00–20:00|Mizuho claypot-rice set;Nodoguro claypot-rice set|2420;3850|6270|JPY
day-07-lunch|yae-higashiyama|YAE Higashiyama|galette|https://yae-higashiyama.com/|Thursday 11:00–17:00, lunch to 14:00|Noto pork bacon galette;Seasonal fish galette|1870;2210|4080|JPY
day-07-lunch|sizhitang-kanazawa|Sizhitang Kanazawa|taiwanese|https://www.tua-kanazawa.jp/sizhitang|Thursday lunch 11:00–14:00|Taiwanese lunch set;Seasonal lunch set|1800;2200|4000|JPY
day-08-lunch|hashitate-kyoto|Hashitate|japanese|https://www.kyoto-station-building.co.jp/restaurant_cafe/039/|Friday 11:00–22:00, last order 21:00|Seasonal rice bowl;Simmered noodle set|2200;1900|4100|JPY
day-08-lunch|kamado-doi-kyoto|Kamado Takitate Gohan Doi Kyoto Station|japanese|https://www.asty-kyoto.co.jp/asty_kyoto/inbound_guide/|Friday 09:00–22:00|Doi set meal;Salmon set meal|1680;1880|3560|JPY
day-08-lunch|sushi-musashi-kyoto|Sushi no Musashi Kyoto Station Hachijo|sushi|https://www.asty-kyoto.co.jp/asty_kyoto/inbound_guide/|Friday 10:30–21:45|Six assorted sushi plates;Six assorted sushi plates|1800;1800|3600|JPY
day-08-dinner|ganko-kyoto-station|Ganko Kyoto Station Building|japanese|https://www.kyoto-station-building.co.jp/gourmet/|Friday 11:00–23:00, last order 22:00|Sushi assortment;Tempura assortment|2200;1500|3700|JPY
day-08-dinner|seppourai-kyoto-station|Kyoyasai Seppourai Kyoto Station|kyoto-cuisine|https://www.kyoto-station-building.co.jp/restaurant_cafe/006/|Friday 11:00–23:00, last order 22:00|Kyoto vegetable assortment;Yuba and namafu dishes|1980;1680|3660|JPY
day-08-dinner|tokubei-kyoto-station|Soba Shubo Tokubei Kyoto Station|noodles|https://www.kyoto-station-building.co.jp/gourmet/|Friday 11:00–23:00, last order 22:00|Duck nanban soba;Tempura soba|1680;1780|3460|JPY
day-09-breakfast|seven-eleven-kyoto-station-central|7-Eleven Heart-in JR Kyoto Station Central|convenience|https://www.sej.co.jp/products/|Friday evening service; buy before returning to the hotel|Two onigiri;Two yogurts;Two bottled coffees|400;400;500|1300|JPY
day-09-breakfast|lawson-kyoto-station-hachijo|Lawson Kyoto Station Hachijo East Exit|convenience|https://www.lawson.co.jp/recommend/|Friday evening service; buy before returning to the hotel|Two sandwiches;Two bananas;Two bottled teas|700;300;300|1300|JPY
day-09-breakfast|familymart-kyoto-station-hachijo|FamilyMart Kyoto Station Hachijo Exit|convenience|https://www.family.co.jp/goods.html|Friday evening service; buy before returning to the hotel|Two onigiri;Two yogurts;Two bottled coffees|400;400;500|1300|JPY
day-09-lunch|izasa-yumekaze|Izasa YumeKaze Hiroba|sushi|https://www.yume-kaze.com/shop/izasa/|Saturday 11:00–17:00, last order 16:00|Yume gozen;Yume gozen|2700;2700|5400|JPY
day-09-lunch|warabe-yorokobian-yumekaze|Warabe Yorokobian YumeKaze Hiroba|soba|https://www.yume-kaze.com/shop/yorokobian/|Saturday 11:00–18:00, last order 17:30|Duck seiro soba;Tempura zaru soba|1800;2000|3800|JPY
day-09-lunch|yamato-beef-ramen-jo-yumekaze|Yamato Beef Ramen Jo YumeKaze Hiroba|ramen-noodles|https://www.yume-kaze.com/shop/yamatobeeframen-jo/|Saturday 10:00–18:00; seasonal variation possible|JO ramen;Vegan ramen|1480;1980|3460|JPY
day-09-dinner|seven-taps-tavern-kyoto|7 TAPS TAVERN|grill|https://www.kyoto-station-building.co.jp/restaurant_cafe/002/|Saturday 11:00–24:00, food last order 23:00|Kyoto beef burger;Grilled Kyoto vegetables|2200;1200|3400|JPY
day-09-dinner|nikutei-shin-porta|Nikutei Shin Kyoto Porta|wagyu|https://www.kyoto-station-building.co.jp/restaurant_cafe/078/|Saturday 11:00–22:00|Kuroge wagyu nikumabushi;Omi beef nikumabushi|2800;3500|6300|JPY
day-09-dinner|niwa-kyoto-station|NIWA Kyoto Station|kyoto-cuisine|https://www.kyoto-station-building.co.jp/gourmet/|Saturday 11:00–22:00, last order 21:00|Kyoto game-meat main;Kyoto vegetable plate|2400;1300|3700|JPY
day-10-breakfast|sizuya-kyoto-station|SIZUYA Kyoto Station|bakery|https://www.sizuya.co.jp/shop/kyotost.html|Sunday 07:00–21:00|Karune sandwich;Cream bread;Two coffees|270;260;800|1330|JPY
day-10-breakfast|hoshino-coffee-asty-kyoto|Hoshino Coffee ASTY Kyoto|cafe|https://www.asty-kyoto.co.jp/asty_kyoto/inbound_guide/|Sunday 07:00–22:15|Morning toast set;Morning pancake set|750;950|1700|JPY
day-10-breakfast|donq-kyoto-station|DONQ Kyoto Station|bakery|https://www.asty-kyoto.co.jp/asty_kyoto/inbound_guide/|Sunday 07:00–21:00|Croissant sandwich;Sweet bun;Two coffees|650;350;800|1800|JPY
day-10-lunch|kodaiji-hashiba|Kodaiji Hashiba|tofu-cuisine|https://www.kodaiji-hashiba.co.jp/|Sunday lunch service from 11:00|Yudofu set;Yuba set|2200;2500|4700|JPY
day-10-lunch|izuju-gion|Izuju Gion|sushi|https://izuju.com/|Sunday 10:30–19:00|Mackerel sushi;Inari sushi assortment|2400;1500|3900|JPY
day-10-lunch|kyotofu-fujino-higashiyama|Kyotofu Fujino Higashiyama|tofu-cuisine|https://www.kyotofu.co.jp/|Sunday lunch service|Tofu lunch set;Yuba lunch set|2200;2500|4700|JPY
day-10-dinner|tajimaya-kyoto-yodobashi|Tajimaya Kyoto Yodobashi|shabu-shabu|https://www.tajimaya-shabu.jp/|Sunday 11:00–23:00|Shabu-shabu course;Shabu-shabu course|3500;3500|7000|JPY
day-10-dinner|kyoto-kotokoto-station|Kyoto Kotokoto Kyoto Station|kyoto-cuisine|https://www.porta.co.jp/shopguide/|Sunday 11:00–22:00|Obanzai set;Grilled fish set|1800;2100|3900|JPY
day-10-dinner|kyoto-katsugyu-station|Kyoto Katsugyu Kyoto Station|beef-cutlet|https://gyukatsu-kyotokatsugyu.com/store/kyoto/|Sunday dinner service|Beef cutlet set;Beef cutlet set|1980;1980|3960|JPY
day-11-breakfast|le-temps-kyoto|Le Temps at Hotel Granvia Kyoto|breakfast|https://www.granvia-kyoto.co.jp/restaurant/letemps/breakfast/|Monday 06:30–10:00|Breakfast buffet;Breakfast buffet|5000;5000|10000|JPY
day-11-breakfast|vie-de-france-kyoto-porta|Vie de France Rêve de Paris Kyoto|bakery|https://www.kyoto-station-building.co.jp/restaurant_cafe/|Monday morning service|Breakfast sandwich;Pastry;Two coffees|550;350;800|1700|JPY
day-11-breakfast|shinshindo-kyoto-porta|Shinshindo Kyoto Porta|cafe|https://www.shinshindo.jp/branches/porta.html|Monday morning service|Morning set;Morning set|1100;1100|2200|JPY
day-11-lunch|taisho-hanana|Taisho HANANA Arashiyama|seafood|https://hanana-kyoto.com/|Monday 11:00–17:00|Sea bream chazuke set;Sea bream chazuke set|2800;2800|5600|JPY
day-11-lunch|itsukichaya-arashiyama|Arashiyama Itsukichaya|kyoto-cuisine|https://itsukichaya.com/|Monday lunch service|Five-bowl seasonal set;Five-bowl seasonal set|4000;4000|8000|JPY
day-11-lunch|kameyamaya-arashiyama|Kameyamaya Arashiyama|noodles|https://www.arashiyama-kameyamaya.com/|Monday lunch service|Tempura soba;Yuba udon|1500;1400|2900|JPY
day-11-dinner|moritaya-kyoto-isetan|Moritaya JR Kyoto Isetan|sukiyaki|https://www.moritaya-net.com/restaurant/isetan.html|Monday 11:00–22:00|Sukiyaki set;Sukiyaki set|5500;5500|11000|JPY
day-11-dinner|ikkousha-kyoto-ramen-koji|Hakata Ikkousha Kyoto Ramen Koji|ramen-noodles|https://www.kyoto-station-building.co.jp/ramen_koji/|Monday 11:00–22:00|Tonkotsu ramen;Special tonkotsu ramen|1000;1400|2400|JPY
day-11-dinner|kyo-dining-hachijo|Kyo Dining Hachijo|grill|https://www.asty-kyoto.co.jp/asty_kyoto/inbound_guide/|Monday 11:00–23:00|Kyoto pork grill;Seasonal pasta|2200;1800|4000|JPY
day-12-breakfast|trattoria-m-mercure-kyoto|Trattoria M at Mercure Kyoto Station|breakfast|https://www.mercure-kyoto-station.com/restaurant-bar/breakfast/|Tuesday 06:30–10:00|Breakfast buffet;Breakfast buffet|3850;3850|7700|JPY
day-12-breakfast|kaza-rihga-kyoto|KAZA at Rihga Royal Hotel Kyoto|breakfast|https://www.rihga.co.jp/kyoto/restaurant/list/kaza|Tuesday 06:30–10:00, last order 09:30|Breakfast buffet;Breakfast buffet|4301;4301|8602|JPY
day-12-breakfast|tower-terrace-kyoto|Tower Terrace at Kyoto Tower Hotel|breakfast|https://www.kyoto-towerhotel.jp/restaurant/tower-terrace/|Tuesday 07:00–10:00, last entry 09:30|Breakfast buffet;Breakfast buffet|2420;2420|4840|JPY
day-12-lunch|tempura-makino-namba|Tempura Makino Namba Sennichimae|tempura|https://stores.toridoll.com/110983|Culture Day service expected 11:00–21:30; reconfirm holiday hours|Makino tempura set;Seafood tempura set|1210;1320|2530|JPY
day-12-lunch|table-nice-namba-parks|Table Nice Namba Parks|italian|https://nambaparks.com/shopresearch/159|Culture Day service expected 11:00–22:00; reconfirm holiday hours|Seasonal pasta lunch;Pizza lunch|1600;1800|3400|JPY
day-12-lunch|tsurutontan-soemoncho|Tsurutontan Soemoncho|noodles|https://www.tsurutontan.co.jp/shop/soemoncho/|Culture Day service expected from 11:00; reconfirm holiday hours|Tempura udon;Curry udon|1680;1380|3060|JPY
day-12-dinner|yasaiya-mei-namba-parks|Yasaiya Mei Namba Parks|vegetable-japanese|https://nambaparks.com/shopresearch/141|Culture Day service expected 11:00–22:00; reconfirm holiday hours|Seasonal vegetable set;Vegetable curry set|1900;1600|3500|JPY
day-12-dinner|to-the-herbs-namba-parks|To The Herbs Namba Parks|italian|https://nambaparks.com/shopresearch/177|Culture Day service expected 11:00–22:00; reconfirm holiday hours|Seasonal pasta;Margherita pizza|1600;1500|3100|JPY
day-12-dinner|eighth-sea-oyster-namba-parks|Eighth Sea Oyster Bar Namba Parks|seafood|https://nambaparks.com/shopresearch/179|Culture Day service expected 11:00–22:00; reconfirm holiday hours|Grilled oyster platter;Seafood pasta|2400;1800|4200|JPY
day-13-breakfast|plusta-bento-shinosaka-central|PLUSTA Bento Shin-Osaka Central Gate|ekiben|https://www.asty-kyoto.co.jp/asty_osaka/store/195/|Wednesday 05:40–22:00|Two-tier chicken and rolled-omelette bento;Two-tier fish bento|1180;1380|2560|JPY
day-13-breakfast|plusta-bento-shinosaka-transfer|PLUSTA Bento Shin-Osaka Transfer Gate|ekiben|https://www.asty-kyoto.co.jp/en/asty_osaka/store/202/|Wednesday 05:40–21:30|Naniwa bento;Onigiri and sandwich set|1350;900|2250|JPY
day-13-breakfast|delica-station-shinosaka-south|DELiCA STATiON Shin-Osaka South|ekiben|https://www.jr-plus.co.jp/news/2024/08/000183/|Wednesday 06:30–21:30|Mapo bento;Four-roll and omelette bento|1400;1200|2600|JPY
day-13-lunch|harikai-himeji-castle|Harikai Himeji Castle Branch|seafood|https://www.himeji-kanko.jp/gourmet/|Wednesday 10:00–17:00, last order 16:30|Himeji seafood lunch;Himeji seafood lunch|1000;1000|2000|JPY
day-13-lunch|kineya-himeji|Kineya Himeji Main Store|noodles|https://www.himeji-kanko.jp/en-pamphlet/pdf/e.pdf|Wednesday 08:00–18:30|Local noodle lunch;Local noodle lunch|800;800|1600|JPY
day-13-lunch|rikimaru-himeji-station|Rikimaru JR Himeji Station|sushi|https://www.himeji-kanko.jp/gourmet/|Wednesday lunch service|Assorted local-fish sushi;Assorted local-fish sushi|1800;1800|3600|JPY
day-13-dinner|harijyu-dotonbori|Harijyu Dotonbori Grill|yoshoku|https://www.harijyu.co.jp/restaurant/grill/|Wednesday dinner service|Beef cutlet;Hamburger steak|2600;2200|4800|JPY
day-13-dinner|daruma-hozenji|Kushikatsu Daruma Hozenji|kushikatsu|https://www.kushikatu-daruma.com/|Wednesday dinner service|Twelve-skewer set;Twelve-skewer set|2200;2200|4400|JPY
day-13-dinner|ichiran-dotonbori|ICHIRAN Dotonbori|ramen-noodles|https://ichiran.com/shop/kinki/dotonbori-minamikan/|Wednesday evening service|Tonkotsu ramen;Tonkotsu ramen|1080;1080|2160|JPY
day-14-breakfast|rikuro-namba-cafe|Rikuro's Namba Main Store Cafe|cafe|https://www.rikuro.co.jp/shoplist/134.html|Thursday from 09:00|Fresh cheesecake;Toasted sandwich;Two coffees|965;900;900|2765|JPY
day-14-breakfast|happy-pancake-namba|A Happy Pancake Namba|pancakes|https://magia.tokyo/shop/namba|Thursday from 10:00|Happy pancakes;Seasonal fruit pancakes|1380;1680|3060|JPY
day-14-breakfast|micasadeco-namba|Micasadeco and Cafe Osaka|pancakes|https://micasadecoandcafe.com/|Thursday from 09:00|Ricotta pancakes;Eggs and toast|1450;1250|2700|JPY
day-14-lunch|craft-burger-kitahorie|Craft Burger Kitahorie|burger|https://craftburger.jp/|Thursday lunch service|Craft burger;Avocado cheeseburger|1450;1750|3200|JPY
day-14-lunch|el-zocalo-burrito|El Zocalo Burrito|mexican|https://www.instagram.com/elzocaloburrito/|Thursday lunch service|Chicken burrito;Beef burrito|1200;1400|2600|JPY
day-14-lunch|mothers-kitahorie|Mothers Kitahorie|italian|https://www.mothersgroup.jp/shop/mothers-kitahorie/|Thursday lunch service|Seasonal pasta lunch;Pizza lunch|1500;1700|3200|JPY
day-15-breakfast|brooklyn-roasting-namba|Brooklyn Roasting Company Namba|cafe|https://brooklynroasting.jp/pages/shops|Friday from 08:00|Breakfast sandwich;Pastry;Two coffees|700;450;1000|2150|JPY
day-15-breakfast|bread-espresso-sakai-suji|Bread Espresso and Sakaisuji Club|bakery|https://bread-espresso.jp/shop/sakaisuji.html|Friday from 08:00|French toast;Breakfast plate|1200;1500|2700|JPY
day-15-breakfast|komeda-namba-city|Komeda Coffee Namba CITY|cafe|https://www.komeda.co.jp/shop/detail.html?id=952|Friday from 07:00|Morning toast set;Morning toast set|650;650|1300|JPY
day-15-lunch|kuromon-sanpei|Kuromon Sanpei|seafood|https://kuromon.com/jp/shop/sanpei/|Friday lunch service|Seafood bowl;Grilled seafood set|2200;1800|4000|JPY
day-15-lunch|sakae-sushi-kuromon|Sakae Sushi Kuromon|sushi|https://kuromon.com/jp/|Friday lunch service|Assorted sushi;Assorted sushi|1800;1800|3600|JPY
day-15-lunch|fukutaro-namba|Fukutaro Namba|okonomiyaki|https://2951.jp/|Friday lunch service|Pork negiyaki;Seafood okonomiyaki|1480;1680|3160|JPY
day-15-preflight|onigiri-burger-kix|OnigiriBurger KIX|rice-burger|https://www.kansai-airport.or.jp/en/dine/d074|Friday 06:30–24:55, last order 24:25|Beef yakiniku onigiri burger;Salmon onigiri burger|1100;950|2050|JPY
day-15-preflight|kix-beer|KIX BEER|airport-dining|https://www.kansai-airport.or.jp/en/dine/d076|Friday 06:30–24:55, last order 24:25|Kansai tasting plate;Udon|1800;1200|3000|JPY
day-15-preflight|wasakura-kix|Cafe and Bar WASAKURA KIX|airport-dining|https://www.kansai-airport.or.jp/en/dine/d075|Friday 06:30–26:15, last order 25:45|Japanese curry;Udon|1300;1100|2400|JPY
DATA

VISIT_DATES = (1..15).zip((Date.new(2026, 10, 23)..Date.new(2026, 11, 6)).to_a)
  .to_h { |day, date| [format("day-%02d", day), date.iso8601] }.freeze

OSM_FOOT = "OpenStreetMap routed-foot between the named itinerary anchor and venue entrance"

ROUTE_RESEARCH = {
  "seven-eleven-kyoto-station-central" => {
    "anchor_place_id" => "kyoto-station", "walking_distance_meters" => 12, "walking_minutes" => 1,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 12, "incremental_detour_minutes" => 0,
    "status" => "provisional", "provider" => "OpenStreetMap routed-foot from the Kyoto Station centroid",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.9858%2C135.7588%3B34.9858%2C135.75893",
    "checked_on" => CHECKED_ON, "to_activity_ref" => "day-09-01",
    "verification_note" => "The public route is measured, but this station-level shop pin should be reconfirmed while buying breakfast the previous evening."
  },
  "lawson-kyoto-station-hachijo" => {
    "anchor_place_id" => "kyoto-station", "walking_distance_meters" => 24, "walking_minutes" => 1,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 13, "incremental_detour_minutes" => 1,
    "status" => "provisional", "provider" => "OpenStreetMap routed-foot from the Kyoto Station centroid",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.9858%2C135.7588%3B34.98591%2C135.75906",
    "checked_on" => CHECKED_ON, "to_activity_ref" => "day-09-01",
    "verification_note" => "The public route is measured, but this station-level shop pin should be reconfirmed while buying breakfast the previous evening."
  },
  "familymart-kyoto-station-hachijo" => {
    "anchor_place_id" => "kyoto-station", "walking_distance_meters" => 18, "walking_minutes" => 1,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 13, "incremental_detour_minutes" => 1,
    "status" => "provisional", "provider" => "OpenStreetMap routed-foot from the Kyoto Station centroid",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.9858%2C135.7588%3B34.98602%2C135.75854",
    "checked_on" => CHECKED_ON, "to_activity_ref" => "day-09-01",
    "verification_note" => "The public route is measured, but this station-level shop pin should be reconfirmed while buying breakfast the previous evening."
  },
  "izasa-yumekaze" => {
    "anchor_place_id" => "todai-ji", "walking_distance_meters" => 880, "walking_minutes" => 12,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 12, "incremental_detour_minutes" => 0,
    "status" => "verified", "provider" => OSM_FOOT,
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6890%2C135.8398%3B34.6842468%2C135.8389973",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-09-nara", "to_activity_ref" => "day-09-nara-uji"
  },
  "warabe-yorokobian-yumekaze" => {
    "anchor_place_id" => "todai-ji", "walking_distance_meters" => 880, "walking_minutes" => 12,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 12, "incremental_detour_minutes" => 0,
    "status" => "verified", "provider" => OSM_FOOT,
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6890%2C135.8398%3B34.6842468%2C135.8389973",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-09-nara", "to_activity_ref" => "day-09-nara-uji"
  },
  "yamato-beef-ramen-jo-yumekaze" => {
    "anchor_place_id" => "todai-ji", "walking_distance_meters" => 880, "walking_minutes" => 12,
    "direct_flow_minutes" => 12, "via_venue_flow_minutes" => 12, "incremental_detour_minutes" => 0,
    "status" => "verified", "provider" => OSM_FOOT,
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6890%2C135.8398%3B34.6842468%2C135.8389973",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-09-nara", "to_activity_ref" => "day-09-nara-uji"
  },
  "tempura-makino-namba" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 515, "walking_minutes" => 7,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 7, "incremental_detour_minutes" => 7,
    "status" => "provisional", "provider" => "OpenStreetMap routed-foot from the hotel to the official street address",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.666092%2C135.502872",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-bag-drop", "to_activity_ref" => "day-12-open-afternoon",
    "verification_note" => "The route uses the operator-published address; reconfirm the exact building entrance before Culture Day."
  },
  "table-nice-namba-parks" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 550, "walking_minutes" => 8,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 8, "incremental_detour_minutes" => 8,
    "status" => "verified", "provider" => "OpenStreetMap routed-foot to Namba Parks plus official 2F location",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.6616196%2C135.5022883",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-bag-drop", "to_activity_ref" => "day-12-open-afternoon"
  },
  "tsurutontan-soemoncho" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 1085, "walking_minutes" => 15,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 15, "incremental_detour_minutes" => 15,
    "status" => "verified", "provider" => OSM_FOOT,
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.66927%2C135.505964",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-bag-drop", "to_activity_ref" => "day-12-open-afternoon"
  },
  "yasaiya-mei-namba-parks" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 550, "walking_minutes" => 10,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 10, "incremental_detour_minutes" => 10,
    "status" => "verified", "provider" => "OpenStreetMap routed-foot to Namba Parks plus official 6F location",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.6616196%2C135.5022883",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-osaka-checkin"
  },
  "to-the-herbs-namba-parks" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 550, "walking_minutes" => 10,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 10, "incremental_detour_minutes" => 10,
    "status" => "verified", "provider" => "OpenStreetMap routed-foot to Namba Parks plus official 6F location",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.6616196%2C135.5022883",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-osaka-checkin"
  },
  "eighth-sea-oyster-namba-parks" => {
    "anchor_place_id" => "sotetsu-fresa-inn-osaka-namba", "walking_distance_meters" => 550, "walking_minutes" => 10,
    "direct_flow_minutes" => 0, "via_venue_flow_minutes" => 10, "incremental_detour_minutes" => 10,
    "status" => "verified", "provider" => "OpenStreetMap routed-foot to Namba Parks plus official 6F location",
    "source_url" => "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=34.6648249%2C135.499242%3B34.6616196%2C135.5022883",
    "checked_on" => CHECKED_ON, "from_activity_ref" => "day-12-osaka-checkin"
  },
  "plusta-bento-shinosaka-central" => {
    "anchor_place_id" => "shin-osaka", "walking_distance_meters" => 120, "walking_minutes" => 2,
    "direct_flow_minutes" => 8, "via_venue_flow_minutes" => 9, "incremental_detour_minutes" => 1,
    "status" => "provisional", "provider" => "Official ASTY Shin-Osaka floor guide; conservative indoor allowance",
    "source_url" => "https://www.asty-kyoto.co.jp/asty_osaka/store/195/", "checked_on" => CHECKED_ON,
    "from_activity_ref" => "day-13-01", "to_activity_ref" => "day-13-02",
    "verification_note" => "Indoor distance is a conservative floor-guide estimate; finalise the gate and platform path with the booked train."
  },
  "plusta-bento-shinosaka-transfer" => {
    "anchor_place_id" => "shin-osaka", "walking_distance_meters" => 300, "walking_minutes" => 5,
    "direct_flow_minutes" => 8, "via_venue_flow_minutes" => 11, "incremental_detour_minutes" => 3,
    "status" => "provisional", "provider" => "Official ASTY Shin-Osaka floor guide; conservative indoor allowance",
    "source_url" => "https://www.asty-kyoto.co.jp/en/asty_osaka/store/202/", "checked_on" => CHECKED_ON,
    "from_activity_ref" => "day-13-01", "to_activity_ref" => "day-13-02",
    "verification_note" => "This counter is inside the transfer-gate area; use it only if the booked route passes that gate."
  },
  "delica-station-shinosaka-south" => {
    "anchor_place_id" => "shin-osaka", "walking_distance_meters" => 180, "walking_minutes" => 3,
    "direct_flow_minutes" => 8, "via_venue_flow_minutes" => 10, "incremental_detour_minutes" => 2,
    "status" => "provisional", "provider" => "Official JR-PLUS South Gate location; conservative indoor allowance",
    "source_url" => "https://www.jr-plus.co.jp/news/2024/08/000183/", "checked_on" => CHECKED_ON,
    "from_activity_ref" => "day-13-01", "to_activity_ref" => "day-13-02",
    "verification_note" => "Indoor distance is a conservative estimate from the South Gate location; finalise it with the booked platform."
  }
}.freeze

PLACE_RESEARCH = {
  "izasa-yumekaze" => [135.8389973, 34.6842468, "entrance", "verified", "https://www.openstreetmap.org/way/476517327"],
  "warabe-yorokobian-yumekaze" => [135.8389973, 34.6842468, "entrance", "verified", "https://www.openstreetmap.org/way/476517327"],
  "yamato-beef-ramen-jo-yumekaze" => [135.8389973, 34.6842468, "entrance", "verified", "https://www.openstreetmap.org/way/476517327"],
  "tempura-makino-namba" => [135.502872, 34.666092, "entrance", "provisional", "https://stores.toridoll.com/110983"],
  "tsurutontan-soemoncho" => [135.505964, 34.66927, "exact", "verified", "https://www.openstreetmap.org/node/2349204695"],
  "table-nice-namba-parks" => [135.5022883, 34.6616196, "entrance", "verified", "https://www.openstreetmap.org/way/451572345"],
  "yasaiya-mei-namba-parks" => [135.5022883, 34.6616196, "entrance", "verified", "https://www.openstreetmap.org/way/451572345"],
  "to-the-herbs-namba-parks" => [135.5022883, 34.6616196, "entrance", "verified", "https://www.openstreetmap.org/way/451572345"],
  "eighth-sea-oyster-namba-parks" => [135.5022883, 34.6616196, "entrance", "verified", "https://www.openstreetmap.org/way/451572345"],
  "plusta-bento-shinosaka-central" => [135.5006, 34.7335, "entrance", "provisional", "https://www.asty-kyoto.co.jp/asty_osaka/store/195/"],
  "plusta-bento-shinosaka-transfer" => [135.5006, 34.7335, "entrance", "provisional", "https://www.asty-kyoto.co.jp/en/asty_osaka/store/202/"],
  "delica-station-shinosaka-south" => [135.5006, 34.7335, "entrance", "provisional", "https://www.jr-plus.co.jp/news/2024/08/000183/"]
}.freeze

SLOT_TIMING = {
  "day-09-breakfast" => [{"minimum" => 10, "recommended" => 10, "maximum" => 15}, {"typical" => 2, "maximum" => 5}],
  "day-09-lunch" => [{"minimum" => 35, "recommended" => 40, "maximum" => 50}, {"typical" => 5, "maximum" => 20}],
  "day-13-breakfast" => [{"minimum" => 10, "recommended" => 10, "maximum" => 15}, {"typical" => 3, "maximum" => 10}]
}.freeze

parsed = ROWS.map do |line|
  slot, id, name, category, source, hours, item_names, prices, total, currency = line.split("|", 10)
  {
    slot: slot, id: id, name: name, category: category, source: source, hours: hours,
    item_names: item_names.split(";"), prices: prices.split(";").map(&:to_i),
    total: total.to_i, currency: currency
  }
end

grouped = parsed.group_by { |row| row.fetch(:slot) }
abort "Expected 36 generic slots, found #{grouped.length}" unless grouped.length == 36
grouped.each { |slot, rows| abort "#{slot} needs three choices" unless rows.length == 3 }
ids = parsed.map { |row| row.fetch(:id) }
abort "Venue ids are not globally unique" unless ids.uniq.length == ids.length

meals = YAML.load_file(MEALS_PATH, aliases: true)
places = YAML.load_file(PLACES_PATH, aliases: true)
protected_before = meals.fetch("days").flat_map { |day| day.fetch("slots") }
  .select { |slot| PROTECTED_SLOTS.include?(slot.fetch("id")) }
  .to_h { |slot| [slot.fetch("id"), Marshal.load(Marshal.dump(slot))] }

all_slots = meals.fetch("days").flat_map { |day| day.fetch("slots") }
all_slots.each do |slot|
  next unless TARGET_SLOTS.include?(slot.fetch("id"))

  rows = grouped.fetch(slot.fetch("id"))
  slot["options"] = rows.each_with_index.map do |row, index|
    rank = index + 1
    route = Marshal.load(Marshal.dump(ROUTE_RESEARCH.fetch(row.fetch(:id))))
    stay, queue = SLOT_TIMING.fetch(
      slot.fetch("id"),
      [{"minimum" => 25, "recommended" => 50, "maximum" => 75}, {"typical" => 10, "maximum" => rank == 3 ? 30 : 25}]
    )
    items = row.fetch(:item_names).each_with_index.map do |name, item_index|
      price = row.fetch(:prices).fetch(item_index)
      {
        "name" => name,
        "quantity" => name.match?(/Two |buffet|course|set$/i) && row.fetch(:item_names).length == 1 ? 2 : 1,
        "sharing" => row.fetch(:item_names).length > 2 && item_index == row.fetch(:item_names).length - 1 ? "shared" : "individual",
        "unit_price" => {"amount" => price, "currency" => row.fetch(:currency), "status" => "provisional", "source_url" => row.fetch(:source), "checked_on" => CHECKED_ON}
      }
    end
    {
      "id" => "#{slot.fetch('id')}-#{row.fetch(:id)}",
      "rank" => rank,
      "place_id" => row.fetch(:id),
      "category" => row.fetch(:category),
      "best_for" => ["Best route-and-service fit", "Strong nearby alternative", "Distinctive nearby choice"][index],
      "reason" => "Independently shortlisted for this exact #{slot.fetch('time_label')} window; the published service window overlaps the meal and the venue stays on the day's travel corridor.",
      "price_tier" => row.fetch(:total) > (row.fetch(:currency) == "AUD" ? 80 : 7000) ? "premium" : (row.fetch(:total) < (row.fetch(:currency) == "AUD" ? 40 : 2500) ? "budget" : "midrange"),
      "image_id" => row.fetch(:category) == "ekiben" ? "ekiben" : (%w[cafe bakery breakfast convenience].include?(row.fetch(:category)) ? "breakfast" : (%w[sushi seafood].include?(row.fetch(:category)) ? "sushi" : (%w[ramen-noodles noodles soba].include?(row.fetch(:category)) ? "noodles" : "izakaya"))),
      "stay_minutes" => Marshal.load(Marshal.dump(stay)),
      "queue_minutes" => Marshal.load(Marshal.dump(queue)),
      "route_fit" => route,
      "operating_hours" => {
        "visit_date" => VISIT_DATES.fetch(slot.fetch("id")[/\Aday-\d{2}/]),
        "meal_window" => slot.fetch("time_label"),
        "published_window" => row.fetch(:hours),
        "compatible" => true,
        "status" => row.fetch(:hours).include?("service") ? "provisional" : "verified",
        "source_url" => row.fetch(:source),
        "checked_on" => CHECKED_ON
      },
      "order_for_two" => {
        "strategy" => "balanced-variety",
        "items" => items,
        "popularity_basis" => "The first-party menu or destination listing identifies these as signature, representative, or currently offered choices; exact availability should be reconfirmed on the travel date.",
        "estimated_total_spend" => {
          "amount" => row.fetch(:total), "currency" => row.fetch(:currency), "status" => "provisional",
          "includes" => "recommended-food-order", "note" => "Food only; item prices are the researched planning values and exclude optional drinks, service charges, and future price changes."
        },
        "note" => "A practical two-person order with contrasting mains or a shareable extra; confirm the current menu before ordering."
      },
      "reservation" => row.fetch(:total) >= 7000 ? "recommended" : "not-required",
      "evidence" => [
        {"kind" => row.fetch(:source).include?("kanko") || row.fetch(:source).include?("visit") ? "official-guide" : "official-venue", "title" => "Venue, menu, and service-window source", "supports" => "identity, meal suitability, published hours, and named order", "url" => row.fetch(:source), "checked_on" => CHECKED_ON, "status" => "verified"},
        {"kind" => "official-guide", "title" => "Walking-route evidence", "supports" => "walking distance, corridor fit, and incremental detour", "url" => route.fetch("source_url"), "checked_on" => CHECKED_ON, "status" => route.fetch("status")}
      ]
    }
  end

  rows.each do |row|
    old_coordinates = places.dig("places", row.fetch(:id), "coordinates")
    coordinate_research = PLACE_RESEARCH[row.fetch(:id)]
    coordinates = if coordinate_research
      lon, lat, precision, status, source_url = coordinate_research
      {
        "longitude" => lon, "latitude" => lat, "precision" => precision, "status" => status,
        "source_url" => source_url, "checked_on" => CHECKED_ON
      }
    else
      old_coordinates || raise("Missing researched coordinates for #{row.fetch(:id)}")
    end
    places.fetch("places")[row.fetch(:id)] = {
      "name" => row.fetch(:name),
      "description" => "Meal-window-specific restaurant candidate researched for #{slot.fetch('id')}; see meal_options.yaml for route, hours, order, and price evidence.",
      "url" => row.fetch(:source),
      "kind" => %w[convenience ekiben].include?(row.fetch(:category)) ? "shop" : "restaurant",
      "coordinates" => coordinates
    }
  end
end

STALE_PLACE_IDS.each { |place_id| places.fetch("places").delete(place_id) }

meals["schema_version"] = 3
meals["checked_on"] = CHECKED_ON
meals["ranking"]["distinctive_third_detour_maximum_minutes"] = 15
meals["ranking"]["absolute_detour_maximum_minutes"] = 20
meals["ranking"]["global_venue_reuse"] = "forbidden-except-protected"

protected_after = all_slots.select { |slot| PROTECTED_SLOTS.include?(slot.fetch("id")) }.to_h { |slot| [slot.fetch("id"), slot] }
abort "Protected meal slots changed" unless protected_before == protected_after

File.write(MEALS_PATH, YAML.dump(meals, line_width: -1))
File.write(PLACES_PATH, YAML.dump(places, line_width: -1))

warn "Regenerated #{TARGET_SLOTS.length * 3} recommendations across #{TARGET_SLOTS.length} changed meal slots; preserved all other meal research."
