import Foundation

/// Turns off every tool the Codex model could use, so a question (or text on a screenshot) can never lead it to
/// run commands, read the user's files, drive a browser or reach a plugin. Claude runs with `--tools ""`; this is
/// the same promise for Codex. The list was taken from `codex features list` (codex-cli 0.155.1) and checked by
/// sending a turn to a local stand-in server and reading the tool list in the request.
///
/// What stays: a tool named `exec` still appears in the request, but with `code_mode_host` off it fails closed
/// ("code-mode host is disabled") and runs nothing, and the sandbox is read-only on top of that.
///
/// The brain tools (`search_brain`, `read_brain_file`) are deliberately not given to Codex. Checked 2026-11-06 on
/// codex 0.155.1: every subscription model is `code_mode_only`, so an MCP tool is reachable only through the
/// code-mode `exec` tool, and that is exactly what this list turns off. ChatGPT therefore answers from the passages
/// the Mac attached to the question and nothing else. This list must stay whole: never remove an entry to make a
/// tool reachable.
enum CodexToolRestrictions {
    /// Every feature that gives the model a tool or a way outside the conversation. Features already off stay on this
    /// list on purpose, so a CLI update that turns one on does not hand the model a tool.
    static let disabledFeatureNames: [String] = [
        // Running commands
        "shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot", "shell_zsh_fork",
        // Code mode (the JavaScript runner that calls every other tool)
        "code_mode", "code_mode_host", "code_mode_only",
        // Apps, plugins and anything they add
        "apps", "enable_mcp_apps", "plugins", "remote_plugin", "plugin_sharing",
        "skill_mcp_dependency_install", "skill_search", "tool_suggest",
        // Browser and computer control
        "browser_use", "browser_use_external", "browser_use_full_cdp_access", "computer_use", "in_app_browser",
        // Images, files, agents, hooks, memory, the network
        "image_generation", "view_image", "multi_agent", "multi_agent_v2", "hooks", "memories",
        "standalone_web_search", "request_permissions_tool", "artifact", "workspace_dependencies",
        "realtime_conversation", "network_proxy", "sleep_tool", "goals",
    ]

    /// The command line flags for `codex exec` and `codex exec resume`. Web search is not a feature flag, so it
    /// is switched off through its own setting (both the mode and the tool key).
    static var arguments: [String] {
        var flags: [String] = []
        for featureName in disabledFeatureNames {
            flags += ["--disable", featureName]
        }
        flags += ["-c", "web_search=\"disabled\"", "-c", "tools.web_search=false"]
        return flags
    }
}
