using Gtk;

namespace Singularity.Apps.Wave {

    public class TransportBar : Singularity.Widgets.ControlStrip {
        public Button play_button;
        public Button stop_button;
        public ToggleButton record_button;
        public ToggleButton loop_button;
        public ToggleButton metronome_button;
        public Label time_label;
        public Label sel_label;
        public LevelMeter meter;
        public Box extra;

        public signal void play_clicked();
        public signal void stop_clicked();
        public signal void start_clicked();
        public signal void end_clicked();

        public TransportBar() {
            base(6, 6);
            add_css_class("wave-transport");
            var start = add_icon_button("media-skip-backward-symbolic", _("Go to Start (Home)"));
            start.clicked.connect(() => start_clicked());
            play_button = add_icon_button("media-playback-start-symbolic", _("Play or Pause (Space)"));
            play_button.clicked.connect(() => play_clicked());
            stop_button = add_icon_button("media-playback-stop-symbolic", _("Stop"));
            stop_button.clicked.connect(() => stop_clicked());
            var end = add_icon_button("media-skip-forward-symbolic", _("Go to End (End)"));
            end.clicked.connect(() => end_clicked());
            record_button = add_icon_toggle("media-record-symbolic", _("Record (Shift+R)"));
            record_button.add_css_class("wave-record");
            loop_button = add_icon_toggle("media-playlist-repeat-symbolic", _("Loop the Selection"));
            metronome_button = add_icon_toggle("alarm-symbolic", _("Metronome"));
            time_label = add_numeric_label();
            time_label.label = "00:00:00.000";
            time_label.add_css_class("title-4");
            time_label.margin_start = 6;
            time_label.margin_end = 6;
            sel_label = new Label("");
            sel_label.add_css_class("dim-label");
            sel_label.add_css_class("numeric");
            sel_label.hexpand = true;
            sel_label.xalign = 0;
            sel_label.ellipsize = Pango.EllipsizeMode.END;
            sel_label.width_chars = 8;
            append(sel_label);
            extra = new Box(Orientation.HORIZONTAL, 4);
            append(extra);
            meter = new LevelMeter(false);
            meter.valign = Align.CENTER;
            meter.set_size_request(120, 10);
            meter.tooltip_text = _("Output Level");
            append(meter);
        }

        public void set_playing(bool playing) {
            play_button.icon_name = playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
        }
    }
}
