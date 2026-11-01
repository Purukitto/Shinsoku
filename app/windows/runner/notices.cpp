#include "notices.h"

// classic COM support in C++/WinRT needs IUnknown declared first
#include <unknwn.h>

#include <NotificationActivationCallback.h>
#include <new>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

namespace notices {
namespace {

using winrt::Windows::Data::Xml::Dom::XmlDocument;
using winrt::Windows::UI::Notifications::ToastNotification;
using winrt::Windows::UI::Notifications::ToastNotificationManager;
using winrt::Windows::UI::Notifications::ToastNotifier;

constexpr wchar_t kAppId[] = L"xyz.purukitto.shinsoku";

// The click callback's class, named in the registry as the app's activator.
constexpr wchar_t kActivatorName[] = L"{6410BDB8-B047-4B28-BFE3-D6E835BE4F5B}";
constexpr GUID kActivator = {
    0x6410bdb8, 0xb047, 0x4b28, {0xbf, 0xe3, 0xd6, 0xe8, 0x35, 0xbe, 0x4f, 0x5b}};

HWND g_window = nullptr;
UINT g_message = 0;
DWORD g_registration = 0;
ToastNotifier g_notifier{nullptr};

struct Activator
    : winrt::implements<Activator, INotificationActivationCallback> {
  // On a COM thread: hand the arguments to the window's thread.
  HRESULT __stdcall Activate(LPCWSTR, LPCWSTR arguments,
                             const NOTIFICATION_USER_INPUT_DATA*,
                             ULONG) noexcept final {
    auto* copy = new (std::nothrow) std::wstring(arguments ? arguments : L"");
    if (copy && !::PostMessageW(g_window, g_message, 0,
                                reinterpret_cast<LPARAM>(copy))) {
      delete copy;
    }
    return S_OK;
  }
};

struct Factory : winrt::implements<Factory, IClassFactory> {
  HRESULT __stdcall CreateInstance(IUnknown* outer, REFIID iid,
                                   void** result) noexcept final {
    *result = nullptr;
    if (outer) {
      return CLASS_E_NOAGGREGATION;
    }
    return winrt::make_self<Activator>()->QueryInterface(iid, result);
  }

  HRESULT __stdcall LockServer(BOOL) noexcept final { return S_OK; }
};

bool SetString(const wchar_t* name, const std::wstring& value) {
  const std::wstring key =
      std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppId;
  return ::RegSetKeyValueW(
             HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
             static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}

// The bundled app icon, next to the exe.
std::wstring IconPath() {
  wchar_t exe[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring path(exe, length);
  path.erase(path.find_last_of(L'\\') + 1);
  return path + L"data\\flutter_assets\\assets\\icon\\app_icon.ico";
}

}  // namespace

bool Init(HWND window, UINT message) {
  if (g_notifier) {
    return true;
  }
  g_window = window;
  g_message = message;
  // written every time, so a moved copy of the app points at its own icon
  if (!SetString(L"DisplayName", L"Shinsoku") ||
      !SetString(L"IconUri", IconPath()) ||
      !SetString(L"CustomActivator", kActivatorName)) {
    return false;
  }
  try {
    if (!g_registration) {
      winrt::check_hresult(::CoRegisterClassObject(
          kActivator, winrt::make_self<Factory>().get(), CLSCTX_LOCAL_SERVER,
          REGCLS_MULTIPLEUSE, &g_registration));
    }
    g_notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
  } catch (const winrt::hresult_error&) {
    return false;
  }
  return true;
}

bool Show(const std::wstring& xml, const std::wstring& tag) {
  if (!g_notifier) {
    return false;
  }
  try {
    XmlDocument document;
    document.LoadXml(xml);
    ToastNotification toast(document);
    toast.Tag(tag);
    g_notifier.Show(toast);
  } catch (const winrt::hresult_error&) {
    return false;
  }
  return true;
}

void Shutdown() {
  if (g_registration) {
    ::CoRevokeClassObject(g_registration);
    g_registration = 0;
  }
  g_notifier = nullptr;
}

}  // namespace notices
