# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact SUSE Linux GmbH.
#
# ------------------------------------------------------------------------------
#
# Summary: The main dialog, showing a list of all connections and allow user to modify their configuration.
# Authors: Howard Guo <hguo@suse.com>

require "yast"
Yast.import "Package"
Yast.import "Service"
Yast.import "SuSEFirewall"
Yast.import "Summary"

module Yast
    class IPSecConfModule < Module
        include Yast::Logger
        FW_CUSTOMRULES_FILE = "/etc/YaST2/vpn_firewall_rules"

        def initialize
            log.info "IPSecConf is initialised"
            @orig_conf = {}
            @unsupported_conf = []
            @orig_secrets = {}
            @unsupported_secrets = []

            @ipsec_conns = {}
            @ipsec_secrets = {"psk" => [], "rsa" => [], "eap" => [], "xauth" => []}

            @enable_ipsec = false
            @tcp_mss_1024 = false
            @autoyast_modified = false
        end

        def main
            textdomain "vpn"
        end

        # Read system settings, daemon settings, and IPSec configurations.
        def Read
            log.info "IPSecConf.Read is called"
            # Read ipsec.conf and ipsec.secrets
            @orig_conf = SCR.Read(path(".etc.ipsec_conf.all"))
            @orig_secrets = SCR.Read(path(".etc.ipsec_secrets.all"))
            # Establish the internal representation of IPSec connection configuration
            @ipsec_conns = {}
            @unsupported_conf = []
            @orig_conf["value"].each { |kv|
                sect_name_tokens = kv["name"].strip.split(%r{\s+}, 2)
                params = kv["value"]
                if sect_name_tokens.length == 2 && sect_name_tokens[0] == "conn" && sect_name_tokens[1] != "%default"
                    sect_name = sect_name_tokens[1].strip
                    @ipsec_conns[sect_name] = Hash[
                        params.map { |paramkv| [paramkv["name"].strip, paramkv["value"].strip] }
                    ]
                else
                    # CA, config-setup, and %default configurations are not supported
                    @unsupported_conf += [kv["name"].strip]
                end
            }
            log.info "Loaded IPSec configuration: " + @ipsec_conns.keys.to_s
            log.info "Unsupported configuration: " + @unsupported_conf.to_s
            # Establish the internal representation of IPSec secrets
            @ipsec_secrets = {"psk" => [], "rsa" => [], "eap" => [], "xauth" => []}
            log_no_secrets = []
            @unsupported_secrets = []
            @orig_secrets["value"].each { |kv|
                left_side = kv["name"].strip
                right_side_tokens = kv["value"].strip.split(%r{\s+}, 2)
                if right_side_tokens.length == 2 && @ipsec_secrets.has_key?(right_side_tokens[0].downcase)
                    key_type = right_side_tokens[0].strip.downcase
                    key_content = right_side_tokens[1].strip.delete '"'
                    @ipsec_secrets[key_type] += [{"id" => left_side, "secret" => key_content}]
                    log_no_secrets += [(left_side + " " + key_type).strip]
                else
                    @unsupported_secrets += [(left_side + ' ' + right_side_tokens[0]).strip]
                end
            }
            log.info "Loaded IPSec keys and secrets: " + log_no_secrets.to_s
            log.info "Unsupported secrets " + @unsupported_secrets.to_s
            # Read daemon settings
            @enable_ipsec = Service.Enabled("strongswan")
            customrules_content = SCR.Read(path(".target.string"), FW_CUSTOMRULES_FILE)
            @tcp_mss_1024 = customrules_content != nil && customrules_content.include?("--set-mss 1024")
            @autoyast_modified = false
        end

        # Return raw ipsec.conf deserialised by SCR.
        def GetDeserialisedIPSecConf
            return @orig_conf
        end

        # Return raw ipsec.secrets deserialised by SCR.
        def GetDeserialisedIPSecSecrets
            return @orig_secrets
        end

        # Return all connection configurations.
        def GetIPSecConnections
            return @ipsec_conns
        end

        # Return the section names of unsupported connection configuration.
        def GetUnsupportedConfiguration
            return @unsupported_conf
        end

        # Return IPSec passwords/secrets configuration.
        def GetIPSecSecrets
            return @ipsec_secrets
        end

        # Return the names of unsupported IPSec password/secret types.
        def GetUnsupportedSecrets
            return @unsupported_secrets
        end

        # Return true if IPSec daemon is enabled, otherwise false.
        def DaemonEnabled
            return @enable_ipsec
        end

        # Return true if TCP MSS 1024 workaround is enabled, otherwise false.
        def TCPMSS1024Enabled
            return @tcp_mss_1024
        end

        # Create a firewall configuration script for all VPN gateways. Return the script content
        def GenFirewallScript
            # Find the gateway VPNs offering Internet connectivity, and collect the client's address pool.
            inet_access_networks = @ipsec_conns.select { |name, conf|
                leftsubnet = conf["leftsubnet"]
                leftsubnet != nil && (leftsubnet.include?("::/0") || leftsubnet.include?("0.0.0.0/0"))
            }.map{|name, conf| conf["rightsourceip"]}

            script = "# The file is automatically generated by YaST VPN module.\n" +
                    "# You may run the file using bourne-shell-compatible interpreter.\n"
            func_template = "%s() {\n%strue\n}\n%s\n"
            # Open ports for IKE and allow ESP protocol
            dport_accept_template = "%s -A INPUT -p udp --dport %d -j ACCEPT\n"
            p_accept_template = "%s -A INPUT -p %d -j ACCEPT\n"
            open_prot = ""
            if @ipsec_conns.length > 0
                open_prot = dport_accept_template % ["iptables", 500] +
                            dport_accept_template % ["iptables", 4500] +
                            dport_accept_template % ["ip6tables", 500] +
                            dport_accept_template % ["ip6tables", 4500]
                open_prot += p_accept_template % ["iptables", 50] +
                             p_accept_template % ["ip6tables", 50]
            end
            script += func_template % ["fw_custom_after_chain_creation", open_prot, "fw_custom_after_chain_creation"]
            script += func_template % ["fw_custom_before_port_handling", "", "fw_custom_before_port_handling"]
            # Reduce TCP MSS - if this has to be done, it must come before FORWARD and MASQUERADE
            inet_access = ""
            if @tcp_mss_1024
                inet_access += "iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1024\n" +
                               "ip6tables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1024\n"
            end
            # Forwarding for Internet access
            forward_template = "%s -A FORWARD -s %s -j ACCEPT\n"
            masq_template = "%s -t nat -A POSTROUTING -s %s -j MASQUERADE\n"
            inet_access_networks.each { |cidr|
                if cidr.include?(":")
                    inet_access += forward_template % ["ip6tables", cidr] + masq_template % ["ip6tables", cidr]
                else
                    inet_access += forward_template % ["iptables", cidr] + masq_template % ["iptables", cidr]
                end
            }
            script += func_template % ["fw_custom_before_masq", inet_access, "fw_custom_before_masq"]
            # Nothing in denyall or finished
            script += func_template % ["fw_custom_before_denyall", "", "fw_custom_before_denyall"]
            script += func_template % ["fw_custom_after_finished", "", "fw_custom_after_finished"]
            return script
        end

        # Apply IPSec configuration.
        def Write
            Yast::Builtins.y2milestone("IPSecConf.Write is called, connections are: " + @ipsec_conns.keys.to_s)
            successful = true
            # Write configuration files
            SCR.Write(path(".etc.ipsec_conf.all"), makeIPSecConfINI)
            SCR.Write(path(".etc.ipsec_conf"), nil)
            SCR.Write(path(".etc.ipsec_secrets.all"), makeIPSecSecretsINI)
            SCR.Write(path(".etc.ipsec_secrets"), nil)
            # Install packages
            install_pkgs = []
            if !Package.Installed("strongswan-ipsec") && Package.Available("strongswan-ipsec")
                install_pkgs = ["strongswan-ipsec"]
            end
            if !Package.Installed("strongswan") && Package.Available("strongswan")
                install_pkgs = ["strongswan"]
            end
            if @enable_ipsec && install_pkgs.length > 0
                if !Package.DoInstall(install_pkgs)
                    Report.Error(_("Failed to install IPSec packages."))
                    successful = false
                end
            end
            # Enable/disable daemon
            if @enable_ipsec
                Service.Enable("strongswan")
                if !(Service.Active("strongswan") ? Service.Restart("strongswan") : Service.Start("strongswan"))
                    Report.Error(_("Failed to start IPSec daemon."))
                    successful = false
                end
            else
                Service.Disable("strongswan")
                Service.Stop("strongswan")
            end
            # Configure IP forwarding
            sysctl_modified = false
            if @ipsec_conns.select { |name, conf|
                leftsubnet = conf["leftsubnet"]
                leftsubnet != nil && leftsubnet.include?("0.0.0.0/0")
            }.length > 0
                SCR.Write(path(".etc.sysctl_conf.\"net.ipv4.ip_forward\""), "1")
                SCR.Write(path(".etc.sysctl_conf.\"net.ipv4.conf.all.forwarding\""), "1")
                SCR.Write(path(".etc.sysctl_conf.\"net.ipv4.conf.default.forwarding\""), "1")
                sysctl_modified = true
            end
            if @ipsec_conns.select { |name, conf|
                leftsubnet = conf["leftsubnet"]
                leftsubnet != nil && leftsubnet.include?("::/0")
            }.length > 0
                SCR.Write(path(".etc.sysctl_conf.\"net.ipv6.conf.all.forwarding\""), "1")
                SCR.Write(path(".etc.sysctl_conf.\"net.ipv6.conf.default.forwarding\""), "1")
                sysctl_modified = true
            end
            if sysctl_modified
                SCR.Write(path(".etc.sysctl_conf"), nil)
                sysctl_apply = SCR.Execute(Yast::Path.new(".target.bash_output"), "/sbin/sysctl -p/etc/sysctl.conf 2>&1")
                if !sysctl_apply["exit"].zero?
                    Report.LongError(_("Failed to apply IP forwarding settings using sysctl:") + sysctl_apply["stdout"])
                    successful = false
                end
            end
            # Configure/deconfigure firewall
            SCR.Write(path(".target.string"), FW_CUSTOMRULES_FILE, IPSecConf.GenFirewallScript)
            existing_rules = SCR.Read(path(".sysconfig.SuSEfirewall2.FW_CUSTOMRULES")).strip
            if !existing_rules.include?(FW_CUSTOMRULES_FILE)
                if existing_rules != ""
                    existing_rules += " "
                end
                SCR.Write(path(".sysconfig.SuSEfirewall2.FW_CUSTOMRULES"), existing_rules + FW_CUSTOMRULES_FILE)
                SCR.Write(path(".sysconfig.SuSEfirewall2"), nil)
            end
            if SuSEFirewall.IsEnabled
                if @enable_ipsec
                    if !SuSEFirewall.IsStarted
                        Report.Warning(_("SuSE firewall is enabled but not activated.\n" +
                            "In order for VPN to function properly, SuSE firewall will now be activated."))
                    end
                    if !SuSEFirewall.SaveAndRestartService
                        Report.Error(_("Failed to restart SuSE firewall."))
                        successful = false
                    end
                else
                    if SuSEFirewall.IsStarted && !SuSEFirewall.SaveAndRestartService
                        Report.Error(_("Failed to restart SuSE firewall."))
                        successful = false
                    end
                end
            else
                Report.LongWarning(
                    _("Both VPN gateway and clients require special SuSE firewall configuration.\n" +
                      "SuSE firewall is not enabled, therefore you must manually run the configuration script " +
                      "on every reboot. The script will now once.\n" +
                      "The script is located at %s" % [FW_CUSTOMRULES_FILE]))
                run_fw_script = SCR.Execute(Yast::Path.new(".target.bash_output"), "/bin/bash %s 2>&1" % [FW_CUSTOMRULES_FILE])
                log.info("run_fw_script: " + run_fw_script.to_s)
            end
            @autoyast_modified = false
            return successful
        end

        # Import all daemon settings and configuration (used by both AutoYast and UI).
        def Import(params)
            Yast::Builtins.y2milestone("IPSecConf.Import is called with parameter: " + params.to_s)
            if !params
                return false
            end
            @enable_ipsec = !!params["enable_ipsec"]
            @tcp_mss_1024 = !!params["tcp_mss_1024"]
            @ipsec_conns = params.fetch("ipsec_conns", {})
            @ipsec_secrets = params.fetch("ipsec_secrets", {})
            @autoyast_modified = true
            return true
        end

        # AutoYaST: Export all daemon settings and configuration.
        def Export
            Yast::Builtins.y2milestone("IPSecConf.Export is called, connections are: " + @ipsec_conns.keys.to_s)
            return {
                "enable_ipsec" => @enable_ipsec,
                "tcp_mss_1024" => @tcp_mss_1024,
                "ipsec_conns" => @ipsec_conns,
                "ipsec_secrets" => @ipsec_secrets
            }
        end

        # AutoYaST: Return a rich text summary of the current configuration.
        def Summary
            Yast::Builtins.y2milestone("IPSecConf.Summary is called")
            ret = Summary.AddHeader("", _("VPN Global Settings"))
            ret = Summary.AddLine(ret, _("Enable VPN (IPSec) daemon: %s") % [(!!@enable_ipsec).to_s])
            ret = Summary.AddLine(ret, _("Reduce TCP MSS to 1024: %s") % [(!!@tcp_mss_1024).to_s])
            ret = Summary.AddHeader(ret, _("Gateway and Connections"))
            if @ipsec_conns != nil
                @ipsec_conns.each{|name, conf|
                    if conf["right"] == "%any"
                        # Gateway summary
                        ret = Summary.AddLine(ret, name + ": " +
                                _("A gateway serving clients in ") + conf["rightsourceip"].to_s)
                    else
                        # Client summary
                        ret = Summary.AddLine(ret, name + ": " +
                                _("A client connecting to ") + conf["right"])
                    end
                }
            end
            return ret
        end

        # AutoYaST: Set modified flag to true. Really does nothing to the logic.
        def SetModified
            Yast::Builtins.y2milestone("IPSecConf.SetModified is called")
            @autoyast_modified = true
        end

        # AutoYaST: Get the modified flag.
        def GetModified
            Yast::Builtins.y2milestone("IPSecConf.GetModified is called, modified flag is: " + @autoyast_modified.to_s)
            return @autoyast_modified
        end

        # AutoYaST: Clear all connections and secrets, and reset all flags.
        def Reset
            Yast::Builtins.y2milestone("IPSecConf.Reset is called")
            @orig_conf = {}
            @unsupported_conf = []
            @orig_secrets = {}
            @unsupported_secrets = []

            @ipsec_conns = {}
            @ipsec_secrets = {"psk" => [], "rsa" => [], "eap" => [], "xauth" => []}

            @enable_ipsec = false
            @tcp_mss_1024 = false
            @autoyast_modified = false
        end

        publish :function => :Read, :type => "void ()"
        publish :function => :Write, :type => "boolean ()"
        publish :function => :Import, :type => "boolean (map)"
        publish :function => :Export, :type => "map ()"
        publish :function => :Summary, :type => "string ()"
        publish :function => :SetModified, :type => "void ()"
        publish :function => :GetModified, :type => "boolean ()"

        private
            def mkININode(kind, name, value, root = false)
                return {
                    "comment" => "",
                    "kind" => root ? "section" : kind,
                    "type" => root ? -1 : 0,
                    "name" => name == nil ? "" : name,
                    "value" => value == nil ? [] : value
                }.merge(root || kind == "section" ? {"file" => -1} : {})
            end

            # Make INI nodes from IPSec parameters, for INI agent. Each connection is a section.
            def makeIPSecConfINI
                mkININode(nil, nil,
                    @ipsec_conns.map { | name, params |
                        mkININode("section", "conn " + name, params.map { | pk, pv|
                            mkININode("value", pk, pv, false)
                        }, false)
                    }, true)
            end

            # Make INI nodes from IPSec secrets, for INI agent. There are no sections.
            def makeIPSecSecretsINI
                mkININode(nil, nil,
                    @ipsec_secrets.map { | keytype, idAndSecret |
                        idAndSecret.map { | entry|
                            mkININode(
                                "value",
                                entry["id"],
                                "%s %s" % [keytype.upcase, keytype.upcase == "RSA" ? entry["secret"] : '"' + entry["secret"] + '"'],
                                false
                            )
                        }
                    }.flatten, true)
            end
    end
    IPSecConf = IPSecConfModule.new
    IPSecConf.main
end
