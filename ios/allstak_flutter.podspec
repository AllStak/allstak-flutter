#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint allstak_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'allstak_flutter'
  s.version          = '1.1.0'
  s.summary          = 'AllStak Flutter SDK native crash capture plugin (iOS).'
  s.description      = <<-DESC
AllStak Flutter SDK for error tracking, request telemetry, breadcrumbs,
sanitization, and mobile observability. This pod provides the iOS native
uncaught-exception handler bridged to Dart over the
`io.allstak.flutter/native` MethodChannel.
                       DESC
  s.homepage         = 'https://app.allstak.sa'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AllStak' => 'support@allstak.sa' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*', '*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
