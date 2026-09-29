using GiWifiLite;
using System.Reflection;
using System.Text.Json;

internal static class UiChecks
{
    public static void Run()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { CheckForm(); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) throw new Exception("UI checks failed", failure);
    }

    private static void CheckForm()
    {
        var path = Path.Combine(Path.GetTempPath(), $"giwifi-test-{Guid.NewGuid():N}.json");
        const string initial = """
            {"remember":false,"network_adapter_id":"missing-adapter","network_adapter_name":"测试网卡","network_adapter_address":"192.0.2.1"}
            """;
        File.WriteAllText(path, initial);
        try
        {
            using var form = new MainForm(path);
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            T Field<T>(string name) => (T)typeof(MainForm).GetField(name, flags)!.GetValue(form)!;
            void Call(string name) => typeof(MainForm).GetMethod(name, flags)!.Invoke(form, null);
            void Assert(bool condition, string name)
            {
                if (!condition) throw new Exception(name);
                Console.WriteLine("PASS: " + name);
            }
            var combo = Field<ComboBox>("_adapter");
            Assert(combo.SelectedItem is NetworkAdapter { Id: "missing-adapter", InterfaceIndex: -1 }, "missing saved adapter stays selected after refresh");
            Assert(File.ReadAllText(path) == initial, "loading settings never overwrites stored settings");
            foreach (var state in new[] { "_busy", "_checking" })
            {
                typeof(MainForm).GetField(state, flags)!.SetValue(form, true);
                Call("UpdateOperationControls");
                Assert(!combo.Enabled && !Field<Button>("_check").Enabled && !Field<Button>("_refreshAdapters").Enabled, state + " prevents adapter switch and concurrent status check");
                typeof(MainForm).GetField(state, flags)!.SetValue(form, false);
            }
            Call("UpdateOperationControls");
            Assert(combo.Enabled && Field<Button>("_check").Enabled, "controls unlock after operations finish");
            combo.SelectedIndex = 0;
            using var saved = JsonDocument.Parse(File.ReadAllText(path));
            Assert(saved.RootElement.GetProperty("network_adapter_id").GetString() == "", "switching to system default persists independently of credentials");
            Assert(saved.RootElement.GetProperty("password").GetString() == "", "credentials remain absent when remember is disabled");
            var acName = Field<ComboBox>("_acName");
            Assert(acName.DropDownStyle == ComboBoxStyle.DropDown, "AC name supports custom input");
            Assert(acName.Text == "GiWiFi_lnsfHG (湖光)", "default AC name shows Huguang campus");
            foreach (var (text, raw) in new[] { ("GiWiFi_lnsf (寸金)", "GiWiFi_lnsf"), ("GiWiFi_lnsfHG (湖光)", "GiWiFi_lnsfHG"), ("custom_ac", "custom_ac") })
            {
                acName.Text = text;
                Call("SaveSettings");
                using var acSettings = JsonDocument.Parse(File.ReadAllText(path));
                Assert(acSettings.RootElement.GetProperty("wlan_ac_name").GetString() == raw, "AC selection saves raw name: " + raw);
                Call("LoadSettings");
                Assert(acName.Text == text, "AC name restores selection or custom input: " + text);
            }
            // Realize child controls without displaying an interactive test window.
            form.ShowInTaskbar = false;
            form.Opacity = 0;
            form.StartPosition = FormStartPosition.Manual;
            form.Location = new Point(-32000, -32000);
            form.Show();
            Application.DoEvents();
            using var bitmap = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
            var imagePath = Path.Combine(AppContext.BaseDirectory, "network-adapter-ui.png");
            bitmap.Save(imagePath);
            Console.WriteLine("UI preview: " + imagePath);
        }
        finally { File.Delete(path); }
    }
}
