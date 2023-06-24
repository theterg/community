"""
Applet: Weather Plots
Summary: View hourly weather plots
Description: Using the open-meteo API, display hourly plots of the upcoming weather for your location.
Author: theterg
"""

load("encoding/base64.star", "base64")
load("encoding/csv.star", "csv")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")
load("math.star", "math")
load("encoding/json.star", "json")

CLOUDS = base64.decode("""
iVBORw0KGgoAAAANSUhEUgAAAEAAAAAWCAYAAABwvpo0AAAABGdBTUEAALGPC/xhBQAAAAFzUkdCAdnJLH8AAAAgY0hSTQAAeiYAAICEAAD6AAAAgOgAAHUwAADqYAAAOpgAABdwnLpRPAAAAAZiS0dEAP8A/wD/oL2nkwAAAJ5JREFUWMPtV0EOgCAMo3soj9tH9URiPAADNmBZz0ppaSemFAg0kXN+vGqjE8VbckK6CWaGpnBmRuHW5GoacNKpWxgRWHmSNw1N0oyxphHF6FkOaPd3VYclQiV8dEuttJ5Hz0K7p/BozHv23XUP8PwZgtRlb2ZgNGIjRnwrZVmvWprJupf/d3f/a8Ca0LparSs2ThC/c764T0AgEKjiBY++aaOgJgMNAAAAAElFTkSuQmCC
""")

# This source is derived from a public dashboard provided by the NYS DOH
# https://a816-dohbesp.nyc.gov/IndicatorPublic/beta/key-topics/airquality/realtime/
# It's updated every hour, so there's no need to hit it very often.
DATA_URL = "https://api.open-meteo.com/v1/forecast?latitude=%f&longitude=%f&hourly=%s,%s&temperature_unit=%s&past_days=1&forecast_days=3&timezone=auto"

def hex_2B(val):
    nibble = (val & 0xF0) >> 4
    if nibble < 10:
        ret = chr(ord("0") + nibble)
    else:
        ret = chr(ord("a") + (nibble - 10))
    nibble = (val & 0x0F)
    if nibble < 10:
        ret += chr(ord("0") + nibble)
    else:
        ret += chr(ord("a") + (nibble - 10))
    return ret

def rgb(r, g, b):
    return "#" + hex_2B(r) + hex_2B(g) + hex_2B(b)

def error(reason):
    return render.Root(
            child = render.Box( # This Box exists to provide vertical centering
                render.Row(
                    expanded=True, # Use as much horizontal space as possible
                    main_align="space_evenly", # Controls horizontal alignment
                    cross_align="center", # Controls vertical alignment
                    children = [
                        render.Text(reason)
                    ],
                ),
            ),
        )

VALID_PARAMS = ["temperature_2m", "precipitation_probability"]
PARAM_NAME   = ["Temperature", "Precipitation"]
VALID_REQ_UNITS = ["fahrenheit", "celsius"]

def main(config):
    loc = config.get("location", None)
    if loc == None:
        return error("No Location")
    loc = json.decode(loc)
    param1 = config.get("param1", VALID_PARAMS[0])
    if param1 not in VALID_PARAMS:
        return error("Invalid param %s", param1)
    param2 = config.get("param2", VALID_PARAMS[1])
    if param2 not in VALID_PARAMS:
        return error("Invalid param %s", param2)
    req_units = config.get("units", "fahrenheit")
    if req_units not in VALID_REQ_UNITS:
        return error("Invalid units %s", req_units)
    window_str = config.get("window", "12")
    if len(window_str) == 0 or not window_str.isdigit():
        window_str = "12"
    window = int(window_str)


    print("Arguments: "+str((loc, param1, param2, req_units)))

    rep = http.get(DATA_URL % (float(loc["lat"]), float(loc["lng"]), param1, param2, req_units), ttl_seconds = 60 * 30)  # cache for 30 minutes
    if rep.status_code != 200:
        return error("Request fail %d", rep.status_code)
    # for development purposes: check if result was served from cache or not
    if rep.headers.get("Tidbyt-Cache-Status") == "HIT":
        print("Hit! Displaying cached data.")
    else:
        print("Miss! Calling API.")

    data = rep.json()
    if not 'hourly_units' in data or not param1 in data['hourly_units'] or not param2 in data['hourly_units']:
        print("Cannot find units: "+str(data.get('hourly_units', {})))
        return error("Cannot find units")
    units = (data['hourly_units'][param1], data['hourly_units'][param2])
    if not time.is_valid_timezone(loc['timezone']):
        print("Invalid Timezone "+str(loc['timezone']))
        return error("Invalid Timezone")
    if not 'hourly' in data:
        return error("No data returned")
    data = data['hourly']

    dataset1 = []
    dataset2 = []
    minmax1 = [999999999.0, -999999999.0]
    minmax2 = [999999999.0, -999999999.0]
    t0 = time.now()
    idx0 = 0
    hist = int(math.round(window/6))
    hours = []
    for idx in range(len(data['time'])):
        t = time.parse_time(data['time'][idx], "2006-01-02T15:04", loc['timezone'])
        x = (t - t0).hours
        y1 = data[param1][idx]
        y2 = data[param2][idx]
        if x < 0:
            idx0 = idx
        if (t - t0).hours > -hist:
            if y1 < minmax1[0]:
                minmax1[0] = y1
            if y1 > minmax1[1]:
                minmax1[1] = y1
            if y2 < minmax2[0]:
                minmax2[0] = y2
            if y2 > minmax2[1]:
                minmax2[1] = y2
        dataset1.append((x, y1))
        dataset2.append((x, y2))
        if t.hour == 0:
            hours.append('12a')
        elif t.hour == 12:
            hours.append('12p')
        elif t.hour < 12:
            hours.append(str(t.hour)+'a')
        else:
            hours.append(str(t.hour-12)+'p')
        if idx - idx0 >= window:
            break

    if units[1] == '%':
        minmax2[0] = 0
        minmax2[1] = 100

    plot_w = 64 
    plot_h = 27

    dataset1 = dataset1[idx0-hist:]
    dataset2 = dataset2[idx0-hist:]
    hours = hours[idx0-hist:]
    print(hours)

    ax0cross = math.ceil(hist * plot_w/len(dataset1))

    color1 = '#0f0'
    color2 = '#f0f'

    plot1= render.Plot(
        data = dataset1,
        width = plot_w,
        height = plot_h,
        color = color1, 
        y_lim = (minmax1[0], minmax1[1]),
    )
    plot2= render.Plot(
        data = dataset2,
        width = plot_w,
        height = plot_h,
        color = color2,
        y_lim = (minmax2[0], minmax2[1]),
    )

    # Overlay plot on top of clouds and colored background
    plot = render.Box(render.Stack(
        children = [
            render.Box(color = '#004', width=64, height=plot_h),
            render.Padding(render.Box(render.Image(src = CLOUDS), width=plot_w-ax0cross, height=plot_h), (ax0cross,0,0,0)),
            render.Padding(render.Box(color='#777', width=1, height=plot_h), (ax0cross, 0, 0, 0)),
            render.Padding(render.Box(color='#777', width=plot_w, height=1), (0, plot_h-1, 0, 0)),
            plot1,
            plot2,
        ],
    ), width=64, height=plot_h)

    yaxis1 = render.Box(render.Stack(children = [
        render.Padding(render.Text(str(math.floor(minmax1[0])), font='CG-pixel-3x5-mono'), (0, 0, 0,0)),
    ]), width=5, height=27)
    yaxis2 = render.Box(color = '#040', width=5, height=27)
    xaxis = render.Box(render.Stack(children = [
        render.Padding(render.Text(str(window), font='CG-pixel-3x5-mono'), (54, 0, 0,0)),
        render.Padding(render.Text('0', font='CG-pixel-3x5-mono'), (ax0cross+3, 0, 0,0)),
    ]), width=64, height=5)

    laxis_text = (str(math.floor(minmax1[0])), str(math.floor(minmax1[1])))
    raxis_text = (str(math.floor(minmax2[0])), str(math.floor(minmax2[1])))

    plot_w_eff = 64 - ax0cross - 1

    return render.Root(
        child = render.Stack(children=[
            render.Padding(plot, (0,0,0,0)),
            render.Padding(render.Text(hours[-1], font='CG-pixel-3x5-mono'), (64-4*len(hours[-1]), plot_h, 0,0)),
            render.Padding(render.Text(hours[hist+int(window/3)], font='CG-pixel-3x5-mono'), (ax0cross + int((54-ax0cross)/3), plot_h, 0,0)),
            render.Padding(render.Text(hours[hist+int(2*window/3)], font='CG-pixel-3x5-mono'), (ax0cross + int(2*(54-ax0cross)/3), plot_h, 0,0)),
            render.Padding(render.Text(hours[hist], font='CG-pixel-3x5-mono'), (ax0cross-2, plot_h, 0,0)),
            render.Padding(render.Text(laxis_text[0], color='afa', font='CG-pixel-3x5-mono'), (0, plot_h-6, 0,0)),
            render.Padding(render.Text(laxis_text[1], color='afa', font='CG-pixel-3x5-mono'), (0, 0, 0,0)),
            render.Padding(render.Text(raxis_text[0], color='faf', font='CG-pixel-3x5-mono'), (64-4*len(raxis_text[0]), plot_h-6, 0,0)),
            render.Padding(render.Text(raxis_text[1], color='faf', font='CG-pixel-3x5-mono'), (64-4*len(raxis_text[1]), 0, 0,0)),
        ])
    )

def get_schema():
    param_options = []
    for idx in range(len(VALID_PARAMS)):
        param_options.append(schema.Option(
            display = PARAM_NAME[idx],
            value = VALID_PARAMS[idx],
        ))
    unit_options = []
    for unit in VALID_REQ_UNITS:
        unit_options.append(schema.Option(
            display = unit,
            value = unit,
        ))
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Display weather data from this location (mandatory)",
                icon = "locationDot",
            ),
            schema.Dropdown(
                id = "param1",
                name = "Plot #1",
                desc = "Metric to plot on left axis",
                icon = "locationDot",
                default = VALID_PARAMS[0],
                options = param_options,
            ),
            schema.Dropdown(
                id = "param2",
                name = "Plot #2",
                desc = "Metric to plot on right axis",
                icon = "locationDot",
                default = VALID_PARAMS[1],
                options = param_options,
            ),
            schema.Dropdown(
                id = "units",
                name = "Units",
                desc = "Temperature Units",
                icon = "locationDot",
                default = VALID_REQ_UNITS[0],
                options = unit_options,
            ),
            schema.Text(
                id = "window",
                name = "Window Size",
                desc = "Number of datapoints to display",
                icon = "chartSimple",
            ),
        ],
    )
