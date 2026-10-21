# Release builds are shrunk by R8 (the Flutter Gradle plugin turns it on). WorkManager
# opens its Room database by reflection on the generated WorkDatabase_Impl's no-argument
# constructor, and creates each worker by reflection on its (Context, WorkerParameters)
# constructor; R8 removes both as unused, and the app then dies at start-up:
#   NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
