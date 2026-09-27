import 'package:firebase_database/firebase_database.dart';

/// Checks whether the class assigned to a student still has a teacher record.
class StudentClassAccess {
  StudentClassAccess._();

  static DatabaseReference? teacherRef(Map<dynamic, dynamic> student) {
    final teacherId = student['teacher_id']?.toString().trim();
    if (teacherId == null || teacherId.isEmpty) return null;
    return FirebaseDatabase.instance.ref().child('teachers').child(teacherId);
  }

  static Future<bool> exists(Map<dynamic, dynamic> student) async {
    final classId = student['class_id']?.toString().trim();
    if (classId == null || classId.isEmpty) return false;

    final linkedTeacher = teacherRef(student);
    if (linkedTeacher != null) {
      final snapshot = await linkedTeacher.get();
      final teacher = snapshot.value;
      return teacher is Map &&
          teacher['class_id']?.toString().trim() == classId;
    }

    // Older student records may not have teacher_id.
    final snapshot = await FirebaseDatabase.instance
        .ref()
        .child('teachers')
        .orderByChild('class_id')
        .equalTo(classId)
        .limitToFirst(1)
        .get();
    return snapshot.value is Map && (snapshot.value as Map).isNotEmpty;
  }
}
